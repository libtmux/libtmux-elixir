alias LibTmux.Server

tmux = System.find_executable("tmux") || raise "tmux is not on PATH"

by_path = Server.new(executable: tmux, socket: "/run/user/1000/work.sock")
by_name = Server.new(executable: tmux, socket_name: "work")
from_variable = Server.new(executable: tmux, env: %{"LIBTMUX_SOCKET" => "work"})
from_path_variable = Server.new(executable: tmux, env: %{"LIBTMUX_SOCKET_PATH" => "/tmp/w.sock"})
default = Server.new(executable: tmux, env: %{})

%Server{socket: "/run/user/1000/work.sock", socket_name: nil} = by_path
%Server{socket: nil, socket_name: "work"} = by_name
%Server{socket: nil, socket_name: "work"} = from_variable
%Server{socket: "/tmp/w.sock", socket_name: nil} = from_path_variable
%Server{socket: nil, socket_name: nil} = default

IO.puts(
  JSON.encode!(%{
    by_path: by_path.socket,
    by_name: by_name.socket_name,
    from_variable: from_variable.socket_name,
    from_path_variable: from_path_variable.socket,
    default: "tmux chooses"
  })
)
