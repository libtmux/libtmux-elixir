defmodule LibTmux.RefTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Client, Pane, Ref, Server, Session, Window, WindowLink}

  doctest LibTmux.Ref

  test "observation conversion preserves native identities and their own instance" do
    observations = [
      {:session, %Session{id: "$1", server_instance: "session-instance"}},
      {:window, %Window{id: "@2", server_instance: "window-instance"}},
      {:window_link, %WindowLink{id: {"$1", 5, "@2"}, server_instance: "link-instance"}},
      {:pane, %Pane{id: "%3", server_instance: "pane-instance", title: :unavailable}},
      {:client, %Client{id: "/dev/pts/4", server_instance: "client-instance"}}
    ]

    for {entity, observation} <- observations do
      assert {:ok, %Ref{} = ref} = Ref.from_observation(observation)

      assert {ref.entity, ref.id, ref.server_instance} ==
               {entity, observation.id, observation.server_instance}

      assert {:error, %{kind: :stale_target}} = Ref.validate(ref, "another-instance")
    end

    {:ok, link} = Ref.from_observation(elem(Enum.at(observations, 2), 1))
    server = Server.new(executable: "/not-a-tmux", socket: "/not-a-socket")

    assert {:error, %{kind: :invalid_target, phase: :validation, certainty: :no_write}} =
             Window.rename(server, link, "no coercion")
  end

  test "observation conversion refuses malformed identities and non-observations" do
    for observation <- [
          %Pane{id: "3", server_instance: "instance"},
          %Pane{id: "%3", server_instance: :unloaded},
          %WindowLink{id: {"$1", -1, "@2"}, server_instance: "instance"},
          %{id: "%3", server_instance: "instance"},
          %{__struct__: Pane, server_instance: "instance"},
          %Ref{entity: :pane, id: "%3", server_instance: "instance"},
          nil
        ] do
      assert {:error, %{kind: :invalid_target, certainty: :no_write, path: [:target]}} =
               Ref.from_observation(observation)
    end
  end

  test "exact pane IDs reject positional and malformed targets" do
    assert {:ok, ref} = Ref.new(:pane, "%7", "instance-a")
    assert ref.id == "%7"
    assert ref.entity == :pane

    for id <- ["7", "main:0.1", "%7\n", "%+7", "%07", "%-1", "@7", ""] do
      assert {:error, %{kind: :invalid_target, certainty: :no_write}} =
               Ref.new(:pane, id, "instance-a")
    end
  end

  test "references cannot be rebound across server instances" do
    assert {:ok, ref} = Ref.new(:pane, "%7", "instance-a")
    assert :ok = Ref.validate(ref, "instance-a")

    assert {:error, %{kind: :stale_target, certainty: :no_write}} =
             Ref.validate(ref, "instance-b")
  end

  test "window-link references retain the complete observed binding" do
    assert {:ok, link} = Ref.new(:window_link, {"$1", 5, "@4"}, "instance-a")
    assert link.id == {"$1", 5, "@4"}

    assert {:error, %{kind: :invalid_target}} =
             Ref.new(:window_link, {"$1", -1, "@4"}, "instance-a")
  end
end
