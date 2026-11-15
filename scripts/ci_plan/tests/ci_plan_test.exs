# Run with: elixir scripts/ci_plan/tests/ci_plan_test.exs
#
# Proves the plan picks what each event should run, and that it refuses what it
# must. Every refusal has a test, so a planner that accepted everything fails.

Code.require_file("../ci_plan.exs", __DIR__)
ExUnit.start()

defmodule CiPlanTest do
  use ExUnit.Case, async: true

  @manifest CiPlan.load()
  @entries @manifest["required_linux"]
  @names Enum.map(@entries, & &1["tmux"])
  @oldest hd(@names)
  @newest List.last(@names)

  defp run(event, inputs \\ []), do: CiPlan.plan(@manifest, Map.new([event: event] ++ inputs))
  defp cells(result), do: result["matrix"]["include"]
  defp pairs(result), do: for(c <- cells(result), do: {c["tmux"], c["toolchain"]})

  defp refused(message, event, inputs \\ []) do
    error = assert_raise CiPlan.PlanError, fn -> run(event, inputs) end
    assert error.message =~ message
  end

  defp edges(toolchain \\ "reference"), do: [{@oldest, toolchain}, {@newest, toolchain}]

  describe "scopes" do
    test "a push and a pull request run the edges and the tracking toolchain" do
      expected = edges() ++ [{@newest, "tracking"}]
      assert run("push")["scope"] == "edges"
      assert pairs(run("push")) == expected
      assert pairs(run("pull_request")) == expected
      assert pairs(run("workflow_dispatch")) == expected
    end

    test "a schedule and an explicit full scope run the whole table" do
      expected = Enum.map(@names, &{&1, "reference"}) ++ [{@newest, "tracking"}]
      assert run("schedule")["scope"] == "full"
      assert pairs(run("workflow_dispatch", scope: "full")) == expected
    end

    test "an explicit scope beats the event" do
      assert run("push", scope: "full")["scope"] == "full"
      assert run("pull_request", scope: "custom", tmux_ref: "master")["scope"] == "custom"
    end

    test "the manifest alone decides the table" do
      manifest = %{@manifest | "required_linux" => @entries ++ [%{"tmux" => "3.9"}]}
      result = CiPlan.plan(manifest, %{event: "push"})
      assert pairs(result) == [{@oldest, "reference"}, {"3.9", "reference"}, {"3.9", "tracking"}]
    end

    test "one release is both edges, and the tracking toolchain can be optional" do
      one = %{@manifest | "required_linux" => [hd(@entries)], "tmux_minimum" => @oldest}

      assert pairs(CiPlan.plan(one, %{event: "push"})) == [
               {@oldest, "reference"},
               {@oldest, "tracking"}
             ]

      untracked = %{
        @manifest
        | "tracking" => %{"source" => ".tool-versions", "required" => false}
      }

      assert pairs(CiPlan.plan(untracked, %{event: "push"})) == edges()
    end

    test "a scope or an event the plan does not know is refused" do
      refused("scope must be one of", "workflow_dispatch", scope: "everything")
      refused("no scope is defined", "release")
    end
  end

  describe "custom runs" do
    test "a list of refs needs the custom scope, and a custom run needs refs" do
      refused("only used with scope custom", "workflow_dispatch",
        scope: "edges",
        tmux_ref: "master"
      )

      refused("only used with scope custom", "workflow_dispatch", tmux_ref: "master")
      refused("needs tmux-ref", "workflow_dispatch", scope: "custom")
      refused("needs tmux-ref", "workflow_dispatch", scope: "custom", tmux_ref: " , ")
    end

    test "every ref is validated before it reaches the build" do
      for ref <- [
            "3.6b;id",
            "-upload-pack=x",
            "a b",
            "$(id)",
            "a..b",
            "a1b2c3d",
            "topic/",
            "x.lock"
          ] do
        refused("tmux ref", "workflow_dispatch", scope: "custom", tmux_ref: "master," <> ref)
      end
    end

    test "refs keep their order, repeats collapse and each builds on the reference toolchain" do
      sha = String.duplicate("a", 40)

      result =
        run("workflow_dispatch",
          scope: "custom",
          tmux_ref: "#{@oldest}, master,#{sha},#{@oldest}"
        )

      assert Enum.map(cells(result), & &1["ref"]) == [@oldest, "master", sha]
      assert Enum.all?(cells(result), &(&1["toolchain"] == "reference"))
      assert Enum.at(cells(result), 1)["name"] == "Native tmux master / reference"
    end

    test "too many cells are refused" do
      refs = Enum.map_join(0..CiPlan.max_custom_legs(), ",", &"topic-#{&1}")
      refused("at most", "workflow_dispatch", scope: "custom", tmux_ref: refs)

      refused("at most", "workflow_dispatch",
        scope: "custom",
        tmux_ref: "a,b,c,d",
        elixir: "1.19.5,1.20.4",
        otp: "28.3,29.1.2"
      )
    end
  end

  describe "toolchains and runners" do
    test "Elixir and OTP inputs replace the reference pair" do
      result = run("workflow_dispatch", elixir: "1.19.5", otp: "28.3")
      assert pairs(result) == edges("custom")
      assert Enum.all?(cells(result), &({&1["elixir"], &1["otp"]} == {"1.19.5", "28.3"}))

      assert hd(cells(result))["name"] ==
               "Native tmux #{@oldest} / custom (Elixir 1.19.5, OTP 28.3)"

      only_otp = run("workflow_dispatch", scope: "custom", tmux_ref: "master", otp: "28.3")

      assert [{@manifest["reference"]["elixir"], "28.3"}] ==
               for(c <- cells(only_otp), do: {c["elixir"], c["otp"]})

      both =
        run("workflow_dispatch",
          scope: "custom",
          tmux_ref: "master",
          elixir: "1.19.5,1.20.4",
          otp: "28.3,29.1.2"
        )

      assert length(cells(both)) == 4
    end

    test "an unusable version is refused" do
      refused("elixir must name versions", "workflow_dispatch", elixir: "latest")
      refused("otp must name versions", "workflow_dispatch", otp: "29;id")
    end

    test "the runner comes from the known images" do
      assert run("push")["os"] == hd(CiPlan.runners())
      assert run("workflow_dispatch", image: "ubuntu-latest")["os"] == "ubuntu-latest"
      refused("os must be one of", "workflow_dispatch", image: "macos-latest")
    end
  end

  describe "debugging session" do
    test "exactly one cell of a dispatch can open it" do
      for mode <- ["before-tests", "on-failure"] do
        result = run("workflow_dispatch", scope: "custom", tmux_ref: "master", tmate: mode)
        assert Enum.map(cells(result), & &1["tmate"]) == [mode]
      end
    end

    test "it is off by default" do
      for result <- [run("push"), run("workflow_dispatch", scope: "full")] do
        assert Enum.all?(cells(result), &(&1["tmate"] == "off"))
      end
    end

    test "several cells, a push and an unknown mode are refused" do
      refused("exactly one cell", "workflow_dispatch", tmate: "on-failure")

      refused("exactly one cell", "workflow_dispatch",
        scope: "custom",
        tmux_ref: "master,3.8",
        tmate: "on-failure"
      )

      refused("only available on a workflow_dispatch", "push",
        scope: "custom",
        tmux_ref: "master",
        tmate: "on-failure"
      )

      refused("tmate must be one of", "workflow_dispatch",
        scope: "custom",
        tmux_ref: "master",
        tmate: "always"
      )
    end
  end

  describe "outputs" do
    test "the job count is the fixed jobs plus the cells" do
      for result <- [run("push"), run("workflow_dispatch", scope: "full")] do
        assert result["expected_jobs"] == length(cells(result)) + 3
        assert MapSet.size(CiPlan.job_names(result)) == result["expected_jobs"]
      end

      assert run("push")["expected_jobs"] == 6
    end

    test "the output file carries single-line values and the summary lists each cell" do
      file = Path.join(System.tmp_dir!(), "ci-plan-#{System.unique_integer([:positive])}.out")
      on_exit(fn -> File.rm(file) end)
      result = run("push")
      File.write!(file, for({key, value} <- CiPlan.outputs(result), do: "#{key}=#{value}\n"))

      lines = file |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 4
      assert "matrix=" <> json = Enum.find(lines, &String.starts_with?(&1, "matrix="))
      assert JSON.decode!(json) == result["matrix"]
      assert "expected_jobs=6" in lines

      summary = CiPlan.summary(result)
      assert summary =~ "### Native plan: edges"
      assert summary =~ "- Native tmux #{@oldest} / reference"
    end
  end

  describe "the manifest" do
    defp loaded(changes) do
      path = Path.join(System.tmp_dir!(), "support-#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(path) end)
      File.write!(path, JSON.encode!(Map.merge(@manifest, changes)))
      CiPlan.load(path)
    end

    test "must be consistent" do
      assert loaded(%{}) == @manifest

      assert_raise CiPlan.PlanError, ~r/missing required tmux floor/, fn ->
        loaded(%{"tmux_minimum" => "3.2a"})
      end

      assert_raise CiPlan.PlanError, ~r/schema_version 1/, fn ->
        loaded(%{"required_linux" => []})
      end

      assert_raise CiPlan.PlanError, ~r/oldest first/, fn ->
        loaded(%{"required_linux" => Enum.reverse(@entries)})
      end

      assert_raise CiPlan.PlanError, ~r/oldest first/, fn ->
        loaded(%{"required_linux" => [hd(@entries), hd(@entries)]})
      end
    end

    test "the script runs end to end and refuses from the command line" do
      script = Path.expand("../ci_plan.exs", __DIR__)
      {output, 0} = System.cmd("elixir", [script, "plan", "--event", "push"])
      assert JSON.decode!(output)["scope"] == "edges"

      {output, status} =
        System.cmd("elixir", [script, "plan", "--event", "push", "--tmate", "on-failure"],
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "tmate is only available"
    end
  end
end
