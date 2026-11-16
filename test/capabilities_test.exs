defmodule LibTmux.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Control, Error, Server}

  @registry LibTmux.Capabilities
  @context %{server_instance: "test-observation", source: :one_shot, epoch: nil}

  test "named native prerequisites have source-backed decisions" do
    assert Code.ensure_loaded?(@registry), "the named capability registry is missing"

    assert {:ok, report} = apply(@registry, :from_observation, ["3.8", @context])

    for id <- ~w(event-wait event-wait-claim format-argument-quote capture-trim-blank-cells) do
      assert {:ok, decision} = apply(@registry, :status, [report, id])
      assert decision.supported
      assert decision.scope == :tmux_primitive
      assert decision.handling == :refuse
      assert decision.source =~ "https://github.com/tmux/tmux/blob/"
      assert {:ok, ^decision} = apply(@registry, :require, [report, id])
    end
  end

  test "release patches do not promote a feature across its minor boundary" do
    assert Code.ensure_loaded?(@registry), "the named capability registry is missing"

    for {version, quote?, capture?} <- [
          {"3.3", false, false},
          {"3.3a", false, false},
          {"3.4", false, true},
          {"3.6b", false, true},
          {"3.7", true, true},
          {"3.7c", true, true}
        ] do
      assert {:ok, report} = apply(@registry, :from_observation, [version, @context])
      assert apply(@registry, :supports?, [report, "format-argument-quote"]) == quote?
      assert apply(@registry, :supports?, [report, "capture-trim-blank-cells"]) == capture?
      refute apply(@registry, :supports?, [report, "event-wait"])

      assert {:error, %Error{kind: :unsupported_feature, certainty: :no_write}} =
               apply(@registry, :require, [report, "event-wait"])
    end

    for version <- ~w(3.8a 3.8-rc2 next-3.9 4.0 3.3b) do
      assert {:error, %Error{kind: :unsupported_version}} =
               apply(@registry, :from_observation, [version, @context])
    end
  end

  test "unknown feature IDs and altered report decisions cannot grant support" do
    assert Code.ensure_loaded?(@registry), "the named capability registry is missing"
    assert {:ok, report} = apply(@registry, :from_observation, ["3.3", @context])
    altered = %{report | features: Map.put(report.features, "event-wait", %{supported: true})}

    assert {:error, %Error{kind: :unsupported_feature, certainty: :no_write}} =
             apply(@registry, :require, [altered, "event-wait"])

    assert {:error, %Error{kind: :unknown_feature, certainty: :no_write}} =
             apply(@registry, :status, [report, "missing-feature"])

    refute apply(@registry, :supports?, [report, "missing-feature"])
  end

  test "public observation validates a timeout before starting a client" do
    assert Code.ensure_loaded?(Server)
    assert Code.ensure_loaded?(Control)
    assert function_exported?(Server, :capabilities, 2), "Server capability discovery is missing"

    assert function_exported?(Control, :capabilities, 2),
           "Control capability discovery is missing"

    server =
      Server.new(executable: "/nonexistent/capability-client", socket: "/nonexistent/socket")

    assert_raise ArgumentError, fn ->
      apply(Server, :capabilities, [server, [timeout: 0]])
    end
  end
end
