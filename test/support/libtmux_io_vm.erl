-module(libtmux_io_vm).
-export([run/0]).

string(Value) when is_list(Value) -> string(list_to_binary(Value));
string(Value) -> <<(byte_size(Value)):16, Value/binary>>.

run() ->
    case init:get_plain_arguments() of
        ["owner"] ->
            Parent = self(),
            {Owner, Monitor} = spawn_monitor(fun() ->
                Parent ! {ready, open()},
                receive never -> ok end
            end),
            receive {ready, Pids} -> print_pids(Pids) after 750 -> error(owner_startup) end,
            "kill\n" = io:get_line(""),
            exit(Owner, kill),
            receive {'DOWN', Monitor, process, Owner, killed} -> ok
            after 750 -> error(owner_not_down) end,
            io:format("owner-down~n"),
            receive never -> ok end;
        [] ->
            print_pids(open()),
            receive never -> ok end
    end.

print_pids({Helper, Child, Grandchild}) ->
    io:format("~p ~p ~p~n", [Helper, Child, Grandchild]).

open() ->
    Port = open_port({spawn_executable, os:getenv("LIBTMUX_IO_SPIKE")},
                     [binary, exit_status, {packet, 2}]),
    Code = "import os,signal\n"
           "if os.fork()==0:\n"
           " os.setsid()\n"
           " if os.fork()!=0: os._exit(0)\n"
           " signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
           " os.write(1,(str(os.getpid())+'\\n').encode())\n"
           " while True: signal.pause()\n"
           "while True: signal.pause()\n",
    Args = ["/usr/bin/python3", "-c", Code],
    {ok, Cwd} = file:get_cwd(),
    true = port_command(Port, [<<$O,2,0,0:32>>, string(Cwd),
                               <<(length(Args)):16>>, [string(A) || A <- Args], <<0:16>>]),
    Child = receive {Port, {data, <<$S, Pid:32>>}} -> Pid
            after 750 -> error(helper_startup) end,
    true = port_command(Port, <<$R,1,8192:16>>),
    Grandchild = receive {Port, {data, <<$D,1,Line/binary>>}} ->
                            list_to_integer(string:trim(binary_to_list(Line)))
                 after 750 -> error(descendant_startup) end,
    {os_pid, Helper} = erlang:port_info(Port, os_pid),
    {Helper, Child, Grandchild}.
