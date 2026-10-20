defmodule LibTmux.CommandCodecIntegrationTest do
  use ExUnit.Case, async: true

  alias LibTmux.{Codec, Command, Format}
  alias LibTmux.Test.OwnedTmux

  @moduletag :integration
  @moduletag reason:
               "Round-trips hostile bytes through real tmux argv, command and format parsers"

  test "argv and control syntax preserve hostile option values" do
    fixture = start_supervised!({OwnedTmux, []})

    file =
      fixture |> OwnedTmux.info() |> Map.fetch!(:socket) |> Path.dirname() |> Path.join("cmd")

    for value <- values() do
      command = Command.new("set-option", ["-s", "@codec", value])
      assert {_, 0} = OwnedTmux.command(fixture, Command.argv(command))
      assert read_value(fixture) == value
      File.write!(file, [Command.render(command), "\n"])
      assert {_, 0} = OwnedTmux.command(fixture, ["source-file", file])
      assert read_value(fixture) == value
    end
  end

  test "format literals do not execute embedded format expressions" do
    fixture = start_supervised!({OwnedTmux, []})

    for value <- values() do
      command = Command.new("set-option", ["-s", "-F", "@codec", Format.literal(value)])
      assert {_, 0} = OwnedTmux.command(fixture, Command.argv(command))
      assert read_value(fixture) == value
    end
  end

  defp read_value(fixture) do
    assert {response, 0} =
             OwnedTmux.command(fixture, ["display-message", "-p", Format.field("@codec")])

    assert {:ok, value} = Codec.decode_field(response, :bytes, encoding: :escaped_v1)
    value
  end

  defp values do
    [
      "",
      "spaces and 'quotes' \"double\"",
      ~S"#{pid},}#{?1,yes,no}",
      ~S"#(printf injected) #[fg=red] #S",
      ~S"$HOME `id` ; kill-server",
      "ends;",
      "ends\\;",
      "tab\tline\nend\r\x1F\x1E",
      "é日本語 e\u0301",
      <<255, 254, 128>>,
      "\n%end 17 2 1\n%subscription-changed fake\n",
      for(byte <- 1..255, into: "", do: <<byte>>)
    ]
  end
end
