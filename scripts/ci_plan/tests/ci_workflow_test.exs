# Run with: elixir scripts/ci_plan/tests/ci_workflow_test.exs
#
# Proves scaffold.yml takes its cells from the plan and stays bound to the
# release. The workflows are read as text, because the job that runs this test
# has no YAML parser. Each rule has a mutation that has to be reported, so a
# check that stopped looking would fail here.

Code.require_file("../ci_plan.exs", __DIR__)
ExUnit.start()

defmodule CiWorkflowTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @scaffold File.read!(Path.join(@root, ".github/workflows/scaffold.yml"))
  @release File.read!(Path.join(@root, ".github/workflows/release.yml"))
  @cleanup File.read!(Path.join(@root, ".github/workflows/docs-preview-cleanup.yml"))
  @manifest CiPlan.load()
  @sha ~r/@[0-9a-f]{40}(\s|$)/
  @tmate "mxschmitt/action-tmate"
  @build_tmux "libtmux/.github/actions/build-tmux"
  # Spelled in pieces, so the repository-wide search for these names that the
  # support-script policy asks for does not match this test.
  @shell_suffix "." <> "sh"
  @script_languages Regex.compile!("pyth" <> "on3?\\b|\\.p" <> "y\\b|\\.s" <> "h\\b")
  @apt ~r/(?:^|[;&|(!`]|\b(?:sudo|timeout|time|env|exec|xargs|nice|then|do|else))\s*(?:(?:-\S+|\d+|\w+=\S*)\s+)*apt(?:-get)?(?![\w.\/-])/

  # Splitting the text

  defp jobs(text) do
    [_, body] = String.split(text, "\njobs:\n", parts: 2)

    body
    |> String.split(~r/\n(?=  [A-Za-z0-9_-]+:\s*\n)/)
    |> Map.new(fn block ->
      [_, name] = Regex.run(~r/\A\s*([A-Za-z0-9_-]+):/, block)
      {name, block}
    end)
  end

  defp field(job, key) do
    case Regex.run(~r/^    #{Regex.escape(key)}: (.*)$/m, job) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp needs(job),
    do:
      ~r/[A-Za-z0-9_-]+/
      |> Regex.scan(String.trim(field(job, "needs") || "", "[]"))
      |> List.flatten()

  defp steps(job), do: job |> String.split(~r/^(?=      - )/m) |> tl()

  defp dispatch_inputs(text) do
    [_, body] = Regex.run(~r/^  workflow_dispatch:\n    inputs:\n(.*?)^  workflow_call:/ms, text)

    body
    |> String.split(~r/^(?=      [a-z-]+:\s*$)/m, trim: true)
    |> Map.new(fn block ->
      [_, name] = Regex.run(~r/\A\s*([a-z-]+):/, block)
      {name, block}
    end)
  end

  defp options(text) do
    case Regex.run(~r/options: \[(.*?)\]/, text) do
      [_, list] ->
        list |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> unquote_word()))

      nil ->
        nil
    end
  end

  defp unquote_word(word), do: String.replace(word, ["'", "\""], "")

  # What GitHub reads a bare word as under YAML 1.1.
  defp bare_booleans(text) do
    words = ~w(y yes true on n no false off)

    for {name, block} <- dispatch_inputs(text),
        token <- bare_tokens(block),
        String.downcase(token) in words,
        do: "the #{name} input has a bare #{token}, which GitHub reads as a boolean; quote it"
  end

  defp bare_tokens(block) do
    from_list =
      (options(block) &&
         Regex.run(~r/options: \[(.*?)\]/, block)
         |> tl()
         |> hd()
         |> String.split(",")
         |> Enum.map(&String.trim/1)) || []

    from_default =
      for [_, value] <- Regex.scan(~r/^        default: (.*)$/m, block), do: String.trim(value)

    Enum.reject(from_list ++ from_default, &(String.starts_with?(&1, ["'", "\""]) or &1 == ""))
  end

  # The rules

  defp problems(scaffold, release, cleanup \\ @cleanup) do
    jobs = jobs(scaffold)
    code = Regex.replace(~r/^ +description: .*\n(?: {10,}.*\n)*/m, scaffold, "")

    tmux_names =
      for %{"tmux" => tmux} <- @manifest["required_linux"],
          Regex.match?(~r/(?<![\w.])#{Regex.escape(tmux)}(?![\w.])/, code),
          do: "scaffold.yml names tmux #{tmux}, which only the manifest may"

    own_matrix =
      if Regex.match?(~r/^\s+include:/m, scaffold) or String.contains?(code, "required_linux"),
        do: ["scaffold.yml lists its own matrix"],
        else: []

    if not MapSet.subset?(
         MapSet.new(~w(scaffold plan native required-linux)),
         MapSet.new(Map.keys(jobs))
       ) do
      tmux_names ++
        own_matrix ++ ["scaffold.yml needs scaffold, plan, native and required-linux jobs"]
    else
      tmux_names ++
        own_matrix ++
        toolchain_problems(scaffold: scaffold, release: release, "docs-preview-cleanup": cleanup) ++
        native_problems(jobs["native"]) ++
        gate_problems(jobs) ++
        concurrency_problems(scaffold) ++
        input_problems(scaffold, jobs) ++
        step_problems(scaffold, jobs) ++
        release_problems(release) ++
        session_problems(scaffold, jobs, release)
    end
  end

  # The jobs that install the tracking toolchain cannot read .tool-versions
  # before Elixir exists, so each workflow spells its selectors and this holds
  # them to the file.
  defp toolchain_problems(workflows) do
    tracking = CiPlan.tracking_versions()

    for {name, text} <- workflows,
        {key, selector} <- [
          {"TRACKING_OTP", tracking["otp"]},
          {"TRACKING_ELIXIR", tracking["elixir"]}
        ],
        not String.contains?(text, "#{key}: '#{selector}'\n"),
        do: "#{name}: #{key} must be '#{selector}', the selector in .tool-versions"
  end

  defp native_problems(native) do
    [
      {String.contains?(native, "otp-version: ${{ matrix.otp }}") and
         String.contains?(native, "elixir-version: ${{ matrix.elixir }}"),
       "native: the Elixir and OTP versions come from the plan"},
      {needs(native) == ["plan"], "native: must wait for the plan"},
      {field(native, "runs-on") == "${{ needs.plan.outputs.os }}",
       "native: must run on the image the plan chose"},
      {String.contains?(native, "matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}"),
       "native: the matrix must come from the plan"},
      {not Regex.match?(~r/^    if:/m, native),
       "native: the matrix shrinks through the plan, never an if on the job"},
      {field(native, "name") == "${{ matrix.name }}", "native: the job name comes from the plan"},
      {String.contains?(native, "uses: #{@build_tmux}@") and
         Regex.match?(@sha, hd(Regex.run(~r/uses: #{@build_tmux}@\S+.*/, native))) and
         String.contains?(native, "ref: ${{ matrix.ref }}"),
       "native: tmux comes from the shared build-tmux action, pinned to a full commit, at the plan's ref"}
    ]
    |> failed()
  end

  defp gate_problems(jobs) do
    gate = jobs["required-linux"]
    waited = needs(gate)

    results =
      for job <- waited do
        variable =
          Map.get(
            %{"plan" => "PLAN_RESULT", "scaffold" => "CORE_RESULT", "native" => "NATIVE_RESULT"},
            job,
            "#{String.upcase(job)}_RESULT"
          )

        {String.contains?(gate, "#{variable}: ${{ needs.#{job}.result }}") and
           String.contains?(gate, ~s|test "$#{variable}" = success|),
         "required-linux: must require #{job} to have succeeded"}
      end

    failed([
      {field(gate, "name") == "Required Linux checks",
       "required-linux: keeps its name, Required Linux checks"},
      {field(gate, "if") == "always()",
       "required-linux: must run when a job it waits for failed"},
      {MapSet.new(waited) == MapSet.new(Map.keys(jobs)) |> MapSet.delete("required-linux"),
       "required-linux: must wait for every other job"}
      | results
    ])
  end

  defp concurrency_problems(scaffold) do
    group = Regex.run(~r/^concurrency:\n  group: (.*)\n  cancel-in-progress: (.*)$/m, scaffold)

    failed([
      {group != nil and
         String.contains?(
           Enum.at(group, 1),
           "github.event_name == 'workflow_dispatch' && github.run_id ||"
         ), "a dispatch run must have its own concurrency group"},
      {group != nil and String.contains?(Enum.at(group, 1), "|| github.ref") and
         Enum.at(group, 2) == "true",
       "a push and a pull request must still cancel the run they supersede"}
    ])
  end

  defp input_problems(scaffold, jobs) do
    inputs = dispatch_inputs(scaffold)

    unreached =
      for name <- Map.keys(inputs),
          not String.contains?(jobs["plan"], "inputs.#{name} }}"),
          do: "plan: the #{name} input must reach the plan"

    outside_env =
      for line <- String.split(scaffold, "\n"),
          String.contains?(line, "inputs."),
          not Regex.match?(~r/\A\s+[A-Z_]+: \$\{\{ inputs\.[a-z-]+ \}\}\z/, line),
          do: "an input may reach a step only through env"

    call =
      Regex.run(~r/^  workflow_call:\n    inputs:\n      scope:\n(.*?)^\S/ms, scaffold <> "\n_")

    bare_booleans(scaffold) ++
      unreached ++
      Enum.uniq(outside_env) ++
      failed([
        {Enum.sort(Map.keys(inputs)) == ~w(elixir os otp scope tmate tmux-ref),
         "the dispatch inputs are not the plan's"},
        {options(inputs["scope"]) == CiPlan.scopes() and
           String.contains?(inputs["scope"], "default: edges"),
         "the scope input must offer exactly the plan's scopes and default to edges"},
        {options(inputs["os"]) == CiPlan.runners(),
         "the os input must offer exactly the plan's runner images"},
        {not Regex.match?(~r/macos/i, scaffold), "scaffold.yml must not run on macOS"},
        {call != nil and String.contains?(Enum.at(call, 1), "required: true"),
         "the workflow_call scope input must be required"}
      ])
  end

  # The scripts the core job runs, and what no step may call.
  defp step_problems(scaffold, jobs) do
    core = jobs["scaffold"]

    tests =
      for script <- ~w(ci_plan_test ci_workflow_test ci_docs_test),
          not String.contains?(core, "scripts/ci_plan/tests/#{script}.exs"),
          do: "scaffold: must run scripts/ci_plan/tests/#{script}.exs"

    raw_apt =
      for line <- String.split(scaffold, "\n"),
          not String.starts_with?(String.trim_leading(line), "#"),
          Regex.match?(@apt, line),
          do:
            "a run script calls apt or apt-get directly; the build-tmux action runs it with a mirror guard: #{String.trim(line)}"

    foreign =
      for line <- String.split(scaffold, "\n"),
          Regex.match?(@script_languages, line),
          do: "a workflow starts Python or a shell script file: #{String.trim(line)}"

    tests ++ raw_apt ++ foreign
  end

  defp release_problems(release) do
    jobs = jobs(release)
    verify = jobs["verify"] || ""

    failed([
      {String.contains?(verify, "uses: ./.github/workflows/scaffold.yml"),
       "release: verify must call scaffold.yml"},
      {Regex.match?(~r/^    with:\n      scope: full$/m, verify),
       "release: verify must ask for scope full"},
      {needs(jobs["publish"] || "") == ["verify"], "release: publish must wait for verify"}
    ])
  end

  defp session_problems(scaffold, jobs, release) do
    sessions =
      for {name, job} <- jobs,
          step <- steps(job),
          String.contains?(step, @tmate),
          do: {name, step}

    per_session =
      Enum.flat_map(sessions, fn {name, step} ->
        failed([
          {name == "native", "#{name}: a debugging session belongs only in the native job"},
          {Regex.match?(~r/uses: #{Regex.escape(@tmate)}@[0-9a-f]{40} # v/, step),
           "a debugging session must be pinned to a full commit SHA"},
          {String.contains?(step, "limit-access-to-actor: true"),
           "a debugging session must be limited to the actor"},
          {Regex.match?(~r/^        timeout-minutes: /m, step),
           "a debugging session needs its own time limit"},
          {String.contains?(step, "github.event_name == 'workflow_dispatch'") and
             String.contains?(step, "matrix.tmate =="),
           "a debugging session runs only on a dispatch, on the cell the plan chose"}
        ])
      end)

    inputs = dispatch_inputs(scaffold)

    per_session ++
      failed([
        {length(sessions) == 2,
         "the native job must offer a session before the tests and one after a failure"},
        {field(jobs["native"], "timeout-minutes") == "${{ matrix.tmate == 'off' && 5 || 60 }}",
         "native: the job must cap its time and give the debugging cell more"},
        {options(inputs["tmate"]) == CiPlan.tmate_modes() and
           String.contains?(inputs["tmate"], "default: 'off'"),
         "the tmate input must offer exactly the plan's modes and default to off"},
        {String.contains?(jobs["plan"], "TMATE: ${{ inputs.tmate }}") and
           String.contains?(jobs["plan"], ~s|--tmate "$TMATE"|),
         "plan: must pass the tmate input through env"},
        {not String.contains?(release, @tmate),
         "release: a release never opens a debugging session"}
      ])
  end

  defp failed(checks), do: for({false, message} <- checks, do: message)

  # The tests

  test "the workflows follow the plan" do
    assert problems(@scaffold, @release) == []
  end

  test "the release waits for Hex approval before checking public artifacts" do
    publish = jobs(@release)["publish"]

    assert [_, docs_and_install] =
             String.split(publish, "run: mix hex.publish --yes --wait\n", parts: 2)

    assert [_, install] =
             String.split(
               docs_and_install,
               "elixir scripts/wait_for_hexdocs/wait_for_hexdocs.exs\n",
               parts: 2
             )

    assert install =~ "run: elixir scripts/check_hex_install.exs "
  end

  test "no other workflow opens a debugging session" do
    for path <- Path.wildcard(Path.join(@root, ".github/workflows/*.yml")),
        Path.basename(path) != "scaffold.yml" do
      refute File.read!(path) =~ @tmate, path
    end
  end

  test "a quoted block list has no bare boolean" do
    block =
      String.replace(
        @scaffold,
        "        options: ['off', before-tests, on-failure]\n",
        "        options:\n          - 'off'\n          - \"before-tests\"\n          - on-failure\n"
      )

    assert block != @scaffold
    assert bare_booleans(block) == []
  end

  defp mutate(text, %Regex{} = pattern, new) do
    assert Regex.match?(pattern, text), "the mutation target is gone: #{inspect(pattern)}"
    Regex.replace(pattern, text, new, global: false)
  end

  defp mutate(text, old, new) when is_binary(old) do
    assert String.contains?(text, old), "the mutation target is gone: #{old}"
    String.replace(text, old, new, global: false)
  end

  @mutations [
    {"the workflow names a tmux version", :scaffold, "      MIX_ENV: test\n",
     "      MIX_ENV: test\n      TMUX_VERSION: 3.3\n", "names tmux 3.3"},
    {"the workflow lists its own matrix", :scaffold,
     "      matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}",
     "      matrix:\n        include:\n          - name: x", "lists its own matrix"},
    {"the matrix stops coming from the plan", :scaffold,
     "matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}", "matrix: ${{ fromJSON('{}') }}",
     "the matrix must come from the plan"},
    {"the native job runs on a fixed image", :scaffold, "runs-on: ${{ needs.plan.outputs.os }}",
     "runs-on: ubuntu-24.04", "must run on the image the plan chose"},
    {"the native job is skipped by an if", :scaffold,
     "    needs: plan\n    runs-on: ${{ needs.plan.outputs.os }}",
     "    needs: plan\n    if: github.event_name == 'push'\n    runs-on: ${{ needs.plan.outputs.os }}",
     "never an if on the job"},
    {"tmux is built from an unpinned action", :scaffold, ~r/(build-tmux)@[0-9a-f]{40}/,
     "\\1@main", "pinned to a full commit"},
    {"the build ignores the plan's ref", :scaffold, "          ref: ${{ matrix.ref }}",
     "          ref: '3.8'", "at the plan's ref"},
    {"a raw apt-get returns", :scaffold, "      - name: Build tmux",
     "      - name: Prerequisites\n        run: sudo apt-get install --yes jq\n      - name: Build tmux",
     "calls apt or apt-get directly"},
    {"a script file returns", :scaffold, "      - name: Name the tmux binary",
     "      - name: Helper\n        run: ./scripts/helper#{@shell_suffix}\n      - name: Name the tmux binary",
     "Python or a shell script file"},
    {"the gate stops running after a failure", :scaffold, "    if: always()", "    if: success()",
     "must run when a job it waits for failed"},
    {"the gate stops waiting for native", :scaffold, "needs: [plan, scaffold, native]",
     "needs: [plan, scaffold]", "must wait for every other job"},
    {"a dispatch shares the push group", :scaffold,
     "github.event_name == 'workflow_dispatch' && github.run_id || github.ref", "github.ref",
     "its own concurrency group"},
    {"a bare off becomes the default", :scaffold, "default: 'off'", "default: off", "a bare off"},
    {"an input reaches a script directly", :scaffold,
     "          TMUX_REF: ${{ inputs.tmux-ref }}",
     "          TMUX_REF: x\n        run: echo ${{ inputs.tmux-ref }}", "only through env"},
    {"a debugging session loses its pin", :scaffold, ~r/(action-tmate)@[0-9a-f]{40}/, "\\1@main",
     "pinned to a full commit SHA"},
    {"a debugging session opens to everyone", :scaffold, "          limit-access-to-actor: true",
     "          limit-access-to-actor: false", "limited to the actor"},
    {"the release asks for the edges", :release, "      scope: full", "      scope: edges",
     "ask for scope full"},
    {"the upload stops waiting for verification", :release, "    needs: verify\n", "",
     "publish must wait for verify"},
    {"the release opens a session", :release, "    steps:\n",
     "    steps:\n      - uses: #{@tmate}@v3\n", "never opens a debugging session"},
    {"the core job's OTP drifts from the tool versions", :scaffold, "TRACKING_OTP: '",
     "TRACKING_OTP: 'x", "scaffold: TRACKING_OTP must be"},
    {"the core job's Elixir drifts from the tool versions", :scaffold, "TRACKING_ELIXIR: '",
     "TRACKING_ELIXIR: 'x", "scaffold: TRACKING_ELIXIR must be"},
    {"the release's OTP drifts from the tool versions", :release, "TRACKING_OTP: '",
     "TRACKING_OTP: 'x", "release: TRACKING_OTP must be"},
    {"the cleanup's Elixir drifts from the tool versions", :cleanup, "TRACKING_ELIXIR: '",
     "TRACKING_ELIXIR: 'x", "docs-preview-cleanup: TRACKING_ELIXIR must be"},
    {"the native job installs a fixed OTP", :scaffold, "otp-version: ${{ matrix.otp }}",
     "otp-version: '29'", "versions come from the plan"},
    {"the native job installs a fixed Elixir", :scaffold, "elixir-version: ${{ matrix.elixir }}",
     "elixir-version: '1.20'", "versions come from the plan"}
  ]

  for {description, which, old, new, message} <- @mutations do
    test "a mutation is reported: #{description}" do
      {scaffold, release, cleanup} =
        case unquote(which) do
          :scaffold ->
            {mutate(@scaffold, unquote(Macro.escape(old)), unquote(new)), @release, @cleanup}

          :release ->
            {@scaffold, mutate(@release, unquote(Macro.escape(old)), unquote(new)), @cleanup}

          :cleanup ->
            {@scaffold, @release, mutate(@cleanup, unquote(Macro.escape(old)), unquote(new))}
        end

      reported = problems(scaffold, release, cleanup)

      assert Enum.any?(reported, &String.contains?(&1, unquote(message))),
             inspect({unquote(message), reported})
    end
  end
end
