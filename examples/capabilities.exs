alias LibTmux.{Capabilities, Command, Control, Server}

tmux = System.find_executable("tmux") || raise "tmux is not on PATH"

Server.with_owned([executable: tmux], fn server ->
  {:ok, report} = Server.capabilities(server)

  event_wait =
    case Capabilities.require(report, "event-wait") do
      {:ok, %{scope: :tmux_primitive}} ->
        {:ok, %{stdout: ""}} =
          Server.run(server, Command.new("wait-for", ["-E", "-l", "pane-created"]))

        "available"

      {:error, %{kind: :unsupported_feature, certainty: :no_write}} ->
        "refused"
    end

  {:ok, %{value: %{id: id}}} =
    Server.new_session(server, "capabilities", command: {:argv, ["/bin/cat"]})

  {:ok, same_instance} =
    Control.with_connection(
      [server: server, session: {:existing, id}, lane: :host_qualified],
      fn control ->
        {:ok, connected} = Control.capabilities(control)
        connected.server_instance == report.server_instance and is_reference(connected.epoch)
      end
    )

  IO.puts(
    JSON.encode!(%{
      daemon: report.daemon_version,
      event_wait: event_wait,
      same_instance: same_instance
    })
  )
end)
