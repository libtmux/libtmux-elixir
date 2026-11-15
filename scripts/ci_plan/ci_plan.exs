# Plans the native tmux cells of a CI run from priv/tmux/support.json and the
# event that started it, so the workflow lists no tmux version.
#
# Scopes:
#
#   edges   the oldest and newest required release on the reference toolchain,
#           and the tracking toolchain on the newest. The default for a push,
#           a pull request and a dispatch.
#   full    every required release on the reference toolchain, and the
#           tracking toolchain on the newest. A release, a schedule and a
#           dispatch that asks.
#   custom  only the tmux versions, tags, branches or commits a dispatch names,
#           on the reference toolchain, or on the Elixir and OTP versions it
#           names.
#
# Usage:
#   elixir scripts/ci_plan/ci_plan.exs plan --event EVENT [--scope S]
#       [--tmux-ref REFS] [--elixir V] [--otp V] [--os IMAGE] [--tmate MODE]
#       [--github-output FILE] [--summary FILE]

defmodule CiPlan do
  @moduledoc false

  defmodule PlanError do
    defexception [:message]
  end

  @support Path.expand("../../priv/tmux/support.json", __DIR__)

  @scopes ~w(edges full custom)
  @event_scopes %{
    "push" => "edges",
    "pull_request" => "edges",
    "workflow_dispatch" => "edges",
    "schedule" => "full"
  }
  @tmate_modes ~w(off before-tests on-failure)
  @runners ~w(ubuntu-24.04 ubuntu-latest ubuntu-22.04)

  # A mistyped list should fail rather than fan out into a huge matrix.
  @max_custom_legs 12

  # The core job, the plan and the required check, which every run has.
  @fixed_jobs 3

  @core_job "Core units and package"
  @plan_job "plan"
  @required_job "Required Linux checks"

  def scopes, do: @scopes
  def tmate_modes, do: @tmate_modes
  def runners, do: @runners
  def max_custom_legs, do: @max_custom_legs

  @doc "Reads the support manifest and refuses one that cannot drive a matrix."
  def load(path \\ @support) do
    manifest = path |> File.read!() |> JSON.decode!()
    entries = manifest["required_linux"] || []

    if manifest["schema_version"] != 1 or entries == [],
      do: fail("the manifest needs schema_version 1 and required_linux cells")

    names = Enum.map(entries, & &1["tmux"])

    if manifest["tmux_minimum"] not in names, do: fail("missing required tmux floor")

    keys = Enum.map(names, &version_key/1)

    if keys != keys |> Enum.uniq() |> Enum.sort(),
      do: fail("required_linux must list each release once, oldest first")

    manifest
  end

  @doc "Orders 3.3 < 3.3a < 3.4, so the first and last entries are the edges."
  def version_key(version) do
    case Regex.run(~r/\A(\d+)\.(\d+)([a-z]?)\z/, version) do
      [_, major, minor, suffix] -> {String.to_integer(major), String.to_integer(minor), suffix}
      nil -> fail("#{inspect(version)} is not a tmux release")
    end
  end

  @doc "Returns the matrix, the runner image and the job count for one run."
  def plan(manifest, inputs) do
    inputs =
      Map.merge(%{scope: "", tmux_ref: "", elixir: "", otp: "", image: "", tmate: ""}, inputs)

    chosen = resolve_scope(inputs.event, inputs.scope)
    check_scope_inputs(chosen, inputs.tmux_ref)
    runner = choose_image(inputs.image)
    toolchains = select_toolchains(manifest, inputs.elixir, inputs.otp)
    names = Enum.map(manifest["required_linux"], & &1["tmux"])

    specs =
      case chosen do
        "custom" ->
          refs = custom_refs(inputs.tmux_ref)
          legs = length(refs) * length(toolchains)

          if legs > @max_custom_legs,
            do:
              fail(
                "this run would have #{legs} cells; at most #{@max_custom_legs} fit a custom run"
              )

          refs

        "full" ->
          names

        "edges" ->
          Enum.uniq([List.first(names), List.last(names)])
      end

    cells = for spec <- specs, toolchain <- toolchains, do: cell(spec, toolchain)

    cells =
      if chosen != "custom" and hd(toolchains)["toolchain"] == "reference" and
           manifest["tracking"]["required"],
         do:
           cells ++
             [cell(List.last(names), %{"toolchain" => "tracking", "elixir" => "", "otp" => ""})],
         else: cells

    if cells == [], do: fail("the plan has no native cell")
    cells = assign_tmate(inputs.event, inputs.tmate, cells)

    %{
      "scope" => chosen,
      "os" => runner,
      "matrix" => %{"include" => cells},
      "expected_jobs" => @fixed_jobs + length(cells)
    }
  end

  @doc "Decides how much of the table a run covers."
  def resolve_scope(event, scope) do
    cond do
      scope != "" and scope in @scopes ->
        scope

      scope != "" ->
        fail("scope must be one of #{Enum.join(@scopes, ", ")}, not #{inspect(scope)}")

      Map.has_key?(@event_scopes, event) ->
        @event_scopes[event]

      true ->
        fail("no scope is defined for the #{inspect(event)} event")
    end
  end

  @doc "Refuses a list of refs that the scope would silently ignore."
  def check_scope_inputs(scope, tmux_ref) do
    if tmux_ref != "" and scope != "custom", do: fail("tmux-ref is only used with scope custom")
    :ok
  end

  @doc "Splits a comma-separated input, dropping blanks and repeats."
  def split_list(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc "Validates the refs a custom run was asked to build."
  def custom_refs(tmux_ref) do
    case split_list(tmux_ref) do
      [] -> fail("scope custom needs tmux-ref, a comma-separated list of tmux refs")
      refs -> Enum.map(refs, &check_ref/1)
    end
  end

  # The build-tmux action resolves and pins a ref; this only keeps a typo or an
  # option-shaped value from reaching it.
  defp check_ref(ref) do
    cond do
      not Regex.match?(~r/\A[A-Za-z0-9._\/-]{1,64}\z/, ref) ->
        fail("tmux ref #{inspect(ref)} must match [A-Za-z0-9._/-]{1,64}")

      String.starts_with?(ref, "-") or String.contains?(ref, "..") or
          String.ends_with?(ref, ["/", ".lock"]) ->
        fail("tmux ref #{inspect(ref)} is not a usable git ref")

      Regex.match?(~r/\A[0-9a-f]{7,39}\z/, ref) ->
        fail("tmux ref #{inspect(ref)} looks like an abbreviated commit; give all 40 hex digits")

      true ->
        ref
    end
  end

  @doc "The reference pair, or the Elixir and OTP versions a dispatch asked for."
  def select_toolchains(manifest, elixir, otp) do
    elixirs = split_list(elixir)
    otps = split_list(otp)

    for version <- elixirs,
        not Regex.match?(~r/\A\d+\.\d+(\.\d+)?\z/, version),
        do: fail("elixir must name versions such as 1.20.4, not #{inspect(version)}")

    for version <- otps,
        not Regex.match?(~r/\A\d+(\.\d+){0,3}\z/, version),
        do: fail("otp must name versions such as 29.1.2, not #{inspect(version)}")

    if elixirs == [] and otps == [] do
      [%{"toolchain" => "reference", "elixir" => "", "otp" => ""}]
    else
      for e <- if(elixirs == [], do: [manifest["reference"]["elixir"]], else: elixirs),
          o <- if(otps == [], do: [manifest["reference"]["otp"]], else: otps),
          do: %{"toolchain" => "custom", "elixir" => e, "otp" => o}
    end
  end

  @doc "Picks the runner image, which is the one CI always used unless a dispatch asks."
  def choose_image(""), do: hd(@runners)

  def choose_image(image) do
    if image in @runners,
      do: image,
      else: fail("os must be one of #{Enum.join(@runners, ", ")}, not #{inspect(image)}")
  end

  # The ref is what the shared build-tmux action builds: a release it pins, or
  # a tag, branch or commit it resolves.
  defp cell(ref, toolchain) do
    label =
      if toolchain["toolchain"] == "custom",
        do: "custom (Elixir #{toolchain["elixir"]}, OTP #{toolchain["otp"]})",
        else: toolchain["toolchain"]

    %{
      "name" => "Native tmux #{ref} / #{label}",
      "tmux" => ref,
      "ref" => ref,
      "toolchain" => toolchain["toolchain"],
      "elixir" => toolchain["elixir"],
      "otp" => toolchain["otp"],
      "tmate" => "off"
    }
  end

  @doc "Gives exactly one cell the debugging session, or fails."
  def assign_tmate(event, mode, cells) do
    mode = if mode == "", do: "off", else: mode

    cond do
      mode not in @tmate_modes ->
        fail("tmate must be one of #{Enum.join(@tmate_modes, ", ")}, not #{inspect(mode)}")

      mode == "off" ->
        cells

      event != "workflow_dispatch" ->
        fail("tmate is only available on a workflow_dispatch run")

      length(cells) != 1 ->
        fail(
          "tmate needs exactly one cell and this run has #{length(cells)}; " <>
            "use scope custom with one tmux-ref, elixir and otp"
        )

      true ->
        [Map.put(hd(cells), "tmate", mode)]
    end
  end

  @doc "Names the jobs a plan produces, as the workflow names them."
  def job_names(result) do
    MapSet.new([
      @core_job,
      @plan_job,
      @required_job | Enum.map(result["matrix"]["include"], & &1["name"])
    ])
  end

  @doc "Describes a plan for the job summary."
  def summary(result) do
    lines =
      [
        "### Native plan: #{result["scope"]}",
        "",
        "Expected jobs in this workflow: #{result["expected_jobs"]}",
        ""
      ] ++
        Enum.map(result["matrix"]["include"], &"- #{&1["name"]}")

    Enum.join(lines, "\n") <> "\n"
  end

  @doc "Flattens a plan into single-line workflow outputs."
  def outputs(result) do
    %{
      "scope" => result["scope"],
      "os" => result["os"],
      "matrix" => JSON.encode!(result["matrix"]),
      "expected_jobs" => Integer.to_string(result["expected_jobs"])
    }
  end

  @options [
    event: :string,
    scope: :string,
    tmux_ref: :string,
    elixir: :string,
    otp: :string,
    os: :string,
    tmate: :string,
    github_output: :string,
    summary: :string
  ]

  def main(["plan" | arguments]) do
    {options, [], []} = OptionParser.parse(arguments, strict: @options)
    event = options[:event] || fail("--event is required")

    result =
      plan(load(), %{
        event: event,
        scope: options[:scope] || "",
        tmux_ref: options[:tmux_ref] || "",
        elixir: options[:elixir] || "",
        otp: options[:otp] || "",
        image: options[:os] || "",
        tmate: options[:tmate] || ""
      })

    IO.puts(JSON.encode!(result))
    if file = options[:github_output], do: write_outputs(file, result)
    if file = options[:summary], do: File.write!(file, summary(result), [:append])
  rescue
    error in PlanError ->
      IO.puts(:stderr, "plan: #{error.message}")
      System.halt(1)
  end

  def main(_arguments) do
    IO.puts(:stderr, "usage: elixir scripts/ci_plan/ci_plan.exs plan --event EVENT [options]")
    System.halt(2)
  end

  defp write_outputs(file, result) do
    lines = for {key, value} <- outputs(result), do: "#{key}=#{value}\n"
    File.write!(file, lines, [:append])
  end

  defp fail(message), do: raise(PlanError, message)
end

# Run only as the entry point, so the tests can load the module.
if Path.expand(to_string(hd(:init.get_plain_arguments()))) == __ENV__.file,
  do: CiPlan.main(System.argv())
