defmodule LibTmux.APIExamplesIntegrationTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Control, Pane, Ref, Selection, Server, Session, Snapshot, Window}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag reason: "Executes the API reference snippets on an owned tmux server"

  test "server, action and control documentation runs without test-module aliases" do
    fixture = start_supervised!({OwnedTmux, []})
    %{socket: socket} = OwnedTmux.info(fixture)

    server =
      Server.new(
        executable: System.get_env("LIBTMUX_TMUX") || System.find_executable("tmux"),
        socket: socket,
        env: Map.drop(System.get_env(), ["TMUX", "TMUX_PANE"])
      )

    snapshot = Server.snapshot!(server)
    session = snapshot |> Snapshot.sessions() |> Selection.one!()
    window = Session.active_window(snapshot, session)
    pane = snapshot |> Snapshot.panes() |> Selection.one!()
    {:ok, session_ref} = Ref.from_observation(session)
    {:ok, window_ref} = Ref.from_observation(window)
    {:ok, pane_ref} = Ref.from_observation(pane)
    options = [server: server, session: {:existing, session.id}, lane: :host_qualified]

    bindings = [
      server: server,
      session_ref: session_ref,
      window_ref: window_ref,
      pane_ref: pane_ref,
      options: options
    ]

    assert [pane.id] == run_example(Server, executable: server.executable, socket: socket)

    assert {:ok, %{outcome: :completed}} = run_example(Session, :rename, 4, bindings)

    assert {:ok, {:ok, %{outcome: :completed}}} =
             run_example(Control, :with_connection, 2, bindings)

    assert {:ok, :checked} =
             Control.with_connection(options, fn control ->
               bindings = Keyword.put(bindings, :control, control)

               for {module, function, arity} <- [
                     {Control, :execute, 3},
                     {Window, :rename, 4},
                     {Pane, :split, 3},
                     {Pane, :send_text, 4},
                     {Pane, :capture, 3},
                     {Pane, :send_keys, 4}
                   ] do
                 assert {:ok, %{outcome: :completed}} =
                          run_example(module, function, arity, bindings)
               end

               :checked
             end)

    assert {:ok, %{server_exit: 0, pane_exited: true, clients_exited: true}} =
             OwnedTmux.close(fixture)
  end

  defp run_example(module, bindings) do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(module)
    eval_example(doc, bindings, "#{inspect(module)} example")
  end

  defp run_example(module, function, arity, bindings) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)

    {{:function, ^function, ^arity}, _, _, %{"en" => doc}, _} =
      List.keyfind(docs, {:function, function, arity}, 0)

    eval_example(doc, bindings, "#{inspect(module)}.#{function}/#{arity} example")
  end

  defp eval_example(doc, bindings, file) do
    source =
      doc
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "    "))
      |> Enum.map_join("\n", &String.replace_prefix(&1, "    ", ""))

    assert source != "", "missing source for #{file}"

    {result, _binding} = Code.eval_string(source, bindings, file: file)

    result
  end
end
