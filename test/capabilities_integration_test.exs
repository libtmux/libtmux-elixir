defmodule LibTmux.CapabilitiesIntegrationTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Capabilities, Command, Control, Error, ProcessIdentity, Server}

  @moduletag :integration
  @moduletag reason:
               "Checks actual daemon releases, qualified epochs and owned native probe retirement"
  @profiles JSON.decode!(File.read!(Path.expand("../priv/tmux/capabilities.json", __DIR__)))[
              "profiles"
            ]

  defp executable do
    System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux") ||
      raise "capability integration requires tmux"
  end

  defp version do
    {"tmux " <> version, 0} = System.cmd(executable(), ["-V"])
    String.trim(version)
  end

  defp client(server) do
    case System.get_env("LIBTMUX_CAP_CLIENT") do
      nil -> server
      executable -> %{server | executable: executable}
    end
  end

  defp output!(server, name, args) do
    {:ok, %{stdout: output}} = Server.run(server, Command.new(name, args))
    output
  end

  defp observed(result, expected) do
    if Map.has_key?(@profiles, expected) do
      assert {:ok, report} = result
      assert report.daemon_version == expected
      report
    else
      assert {:error, %Error{kind: :unsupported_version}} = result
      nil
    end
  end

  test "one-shot discovery observes the actual daemon without hooks or persistent resources" do
    expected = version()

    directory =
      Server.with_owned([executable: executable()], fn original ->
        server = client(original)
        pid = server |> output!("display-message", ["-p", ~S"#{pid}"]) |> String.trim()
        {:ok, instance} = ProcessIdentity.read(String.to_integer(pid))
        output!(server, "set-option", ["-s", "@capability-hook", "untouched"])

        hooks =
          ["after-display-message"] ++ if(expected == "3.8", do: ["command-error"], else: [])

        for hook <- hooks do
          output!(server, "set-hook", [
            "-g",
            hook,
            "set-option -s @capability-hook ran"
          ])
        end

        if report = observed(Server.capabilities(server), expected) do
          assert report.server_instance == instance
          assert report.source == :one_shot
          assert report.epoch == nil
          assert report.features["event-wait"].scope == :tmux_primitive

          if Capabilities.supports?(report, "event-wait") do
            assert {:ok, _} = Capabilities.require(report, "event-wait")
            assert output!(server, "wait-for", ["-E", "-l", "pane-created"]) == ""
          else
            assert {:error, %Error{kind: :unsupported_feature, certainty: :no_write}} =
                     Capabilities.require(report, "event-wait")
          end
        end

        assert output!(server, "show-options", ["-sv", "@capability-hook"]) == "untouched\n"
        assert output!(server, "list-sessions", []) == ""
        Path.dirname(original.socket)
      end)

    refute File.exists?(directory)
  end

  test "a missing daemon is not started by discovery" do
    directory =
      Path.join(System.tmp_dir!(), "libtmux-elixir-cap-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    try do
      server = Server.new(executable: executable(), socket: Path.join(directory, "missing.sock"))
      assert {:error, %Error{}} = Server.capabilities(server)
      assert File.ls!(directory) == []
    after
      File.rmdir!(directory)
    end
  end

  test "one-shot discovery avoids aliased commands and configured after-hooks" do
    expected = version()

    Server.with_owned([executable: executable()], fn server ->
      {:ok, _session} =
        Server.new_session(server, "capability-hooks", command: {:argv, ["/bin/cat"]})

      for name <- ~w(hook alias) do
        output!(server, "set-option", ["-s", "@capability-#{name}", "untouched"])
      end

      hooks =
        ~w(after-display-message after-show-options) ++
          if(expected == "3.8", do: ["command-error"], else: [])

      for hook <- hooks do
        output!(server, "set-hook", ["-g", hook, "set-option -s @capability-hook ran"])
      end

      for {name, index} <- Enum.with_index(~w(run-shell if-shell display-message), 100) do
        output!(server, "set-option", [
          "-s",
          "command-alias[#{index}]",
          "#{name}=set-option -s @capability-alias ran ; #{name}"
        ])
      end

      result = Server.capabilities(server)

      assert output!(server, "list-commands", [
               "-F",
               ~S"#{@capability-hook},#{@capability-alias}",
               "list-sessions"
             ]) == "untouched,untouched\n"

      observed(result, expected)
    end)
  end

  test "control discovery preserves its accepted epoch and refuses after close" do
    expected = version()

    Server.with_owned([executable: executable()], fn original ->
      server = client(original)

      {:ok, %{value: %{id: id}}} =
        Server.new_session(server, "capabilities", command: {:argv, ["/bin/cat"]})

      assert {:ok, :checked} =
               Control.with_connection(
                 [server: server, session: {:existing, id}, lane: :host_qualified],
                 fn control ->
                   {:ok, status} = Control.status(control)

                   if report = observed(Control.capabilities(control), expected) do
                     assert report.server_instance == status.instance
                     assert report.epoch == status.epoch
                     assert report.source == :control
                   end

                   assert :ok = Control.close(control)
                   assert {:error, %Error{}} = Control.capabilities(control)
                   :checked
                 end
               )
    end)
  end
end
