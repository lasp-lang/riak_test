-module(rtssh).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-define(DEFAULT_BIN_SIZE, 4096).

get_version() ->
    unknown.

get_deps() ->
    "deps".

harness_opts() ->
    %% Option Name, Short Code, Long Code, Argument Spec, Help Message
    [
     {test_name, undefined, "name", {string, "ad-hoc"},
      "name for this test"},
     {bin_size, undefined, "bin-size", {integer, 4096},
      "size of fixed binaries (median for non-fixed)"},
     {bin_type, undefined, "bin-type", {atom, fixed},
      "fixed | exponential"},
     {load_type, undefined, "load-type", {atom, write_heavy},
      "read_heavy | write_heavy"},
     {version, undefined, "version", {string, "master"},
      "version to test"},
     {prepop, undefined, "prepop", {boolean, false},
      "prepopulate cluster"},
     {prepop_size, undefined, "prepop-size", {integer, 0},
      "number of values to prepop (approximate)"},
     {test_type, undefined, "type",  {atom, uniform},
      "uniform | pareto"},
     {stop, undefined, "stop", {boolean, false},
      "stop running riak cluster and start new"},
     {cuttle, undefined, "cuttle", {boolean, true},
      "use cuttlefish config system"},
     {drop_cache, undefined, "drop-cache", {boolean, true},
      "drop file caches before starting bb run"},
     {run_time, undefined, "run-time", {integer, undefined},
      "how long to run the test for"},
     {dataset, undefined, "dataset", {string, ""},
      "use pre-existing dataset and ring (count must match)"}
    ].


setup_harness(_Test, Args) ->
    lager:info("Harness setup with args: ~p", [Args]),
    Version =
        case getopt:parse(harness_opts(), Args) of
            {ok, {Parsed, []}} ->
                V = proplists:get_value(version, Parsed),
                rt_config:set(perf_version, V),
                B = proplists:get_value(bin_size, Parsed),
                rt_config:set(perf_binsize, B),
                BT = proplists:get_value(bin_type, Parsed),
                rt_config:set(perf_bin_type, BT),
                LT = proplists:get_value(load_type, Parsed),
                rt_config:set(perf_load_type, LT),
                T = proplists:get_value(test_type, Parsed),
                rt_config:set(perf_test_type, T),
                N = proplists:get_value(test_name, Parsed),
                rt_config:set(perf_test_name, N),
                D = proplists:get_value(dataset, Parsed),
                rt_config:set(perf_dataset, D),
                RT = proplists:get_value(run_time, Parsed),
                rt_config:set(perf_runtime, RT),
                Fish = proplists:get_value(cuttle, Parsed),
                rt_config:set(cuttle, Fish),
                Drop = proplists:get_value(drop_cache, Parsed),
                rt_config:set(perf_drop_cache, Drop),
                P = proplists:get_value(prepop, Parsed),
                PS = proplists:get_value(prepop_size, Parsed),

                if D =/= "" andalso P ->
                        lager:error("Dataset and prepop are "
                                    "mutually exclusive"),
                        halt(1);
                   true -> ok
                end,
                rt_config:set(perf_prepop, P),
                rt_config:set(perf_prepop_size, PS),
                rt_config:set(perf_restart,
                              proplists:get_value(stop, Parsed)),
                V;
            _Huh ->
                %% lager:info("huh: ~p", [Huh]),
                getopt:usage(harness_opts(),
                             escript:script_name()),
                halt(0)
        end,

    Hosts = load_hosts(),
    rt_config:set(rt_hostnames, Hosts),

    case Version of
        meh ->
            Path = relpath(root),

            %% [io:format("R: ~p~n", [wildcard(Host, "/tmp/*")]) || Host <- Hosts],

            %% Stop all discoverable nodes, not just nodes we'll be using for this test.
            stop_all(Hosts),

            %% Reset nodes to base state
            lager:info("Resetting nodes to fresh state"),
            rt:pmap(fun(Host) ->
                            run_git(Host, Path, "reset HEAD --hard"),
                            run_git(Host, Path, "clean -fd")
                    end, Hosts);
        _ ->
            %% consider separating out the perf stuff as an overlay on the ssh harness

            maybe_stop_all(Hosts)
    end,

    ok.


set_backend(Backend) ->
    %%lager:info("setting backend to ~p", [Backend]),
    rt_config:set(rt_backend, Backend).

get_backends() ->
    [riak_kv_bitcask_backend,
     riak_kv_eleveldb_backend,
     riak_kv_memory_backend].

cmd(Cmd) ->
    cmd(Cmd, []).

cmd(Cmd, Opts) ->
    wait_for_cmd(spawn_cmd(Cmd, Opts)).

deploy_nodes(NodeConfig) ->
    Hosts = rt_config:get(rtssh_hosts),
    NumNodes = length(NodeConfig),
    NumHosts = length(Hosts),
    case NumNodes > NumHosts of
        true ->
            erlang:error("Not enough hosts available to deploy nodes",
                         [NumNodes, NumHosts]);
        false ->
            Hosts2 = lists:sublist(Hosts, NumNodes),
            deploy_nodes(NodeConfig, Hosts2)
    end.

deploy_nodes(NodeConfig, Hosts) ->
    Path = relpath(root),
    lager:info("Riak path: ~p", [Path]),

    Nodes = [list_to_atom("riak@" ++ Host) || Host <- Hosts],
    HostMap = lists:zip(Nodes, Hosts),

    %% NodeMap = orddict:from_list(lists:zip(Nodes, NodesN)),
    %% TODO: Add code to set initial app.config
    {Versions, Configs} = lists:unzip(NodeConfig),
    VersionMap = lists:zip(Nodes, Versions),

    rt_config:set(rt_hosts, HostMap),
    rt_config:set(rt_versions, VersionMap),


    rt:pmap(fun({_, default}) ->
                    ok;
               ({Node, {cuttlefish, Config0}}) ->
                    Host = get_host(Node),
                    Config = Config0 ++
                        [{nodename, atom_to_list(Node)},
                         {"listener.protobuf.internal",
                          Host++":8087"},
                         {"listener.http.internal",
                          Host++":8098"}
                        ],
                    set_conf(Node, Config);
               ({Node, Config}) ->
                    %%lager:info("update ~p", [self()]),
                    update_app_config(Node, Config)
            end,
            lists:zip(Nodes, Configs)),

    timer:sleep(500),

    case rt_config:get(cuttle, true) of
        false ->
            rt:pmap(fun(Node) ->
                            Host = get_host(Node),
                            %%lager:info("ports ~p", [self()]),
                            Config = [{riak_api,
                                       [{pb, fun([{_, Port}]) ->
                                                     [{Host, Port}]
                                             end},
                                        {pb_ip, fun(_) ->
                                                        Host
                                                end}]},
                                      {riak_core,
                                       [{http, fun([{_, Port}]) ->
                                                       [{Host, Port}]
                                               end}]}],
                            update_app_config(Node, Config)
                    end, Nodes),

            timer:sleep(500),

            rt:pmap(fun(Node) ->
                            update_vm_args(Node,
                                           [{"-name", Node},
                                            {"-zddbl", "32768"},
                                            {"-P", "256000"}])
                    end, Nodes),

            timer:sleep(500);
        true -> ok
    end,

    rt:pmap(fun start/1, Nodes),

    Nodes.

start(Node) ->
    run_riak(Node, "start"),
    ok.

stop(Node) ->
    run_riak(Node, "stop"),
    ok.

run_riak(Node, Cmd) ->
    Exec = riakcmd(Node, Cmd),
    lager:info("Running: ~s :: ~s", [get_host(Node), Exec]),
    ssh_cmd(Node, Exec).

run_git(Host, Path, Cmd) ->
    Exec = gitcmd(Path, Cmd),
    lager:info("Running: ~s :: ~s", [Host, Exec]),
    ssh_cmd(Host, Exec).

admin(Node, Args) ->
    Cmd = riak_admin_cmd(Node, Args),
    lager:info("Running: ~s :: ~s", [get_host(Node), Cmd]),
    {0, Result} = ssh_cmd(Node, Cmd),
    lager:info("~s", [Result]),
    {ok, Result}.

riak(Node, Args) ->
    Result = run_riak(Node, Args),
    lager:info("~s", [Result]),
    {ok, Result}.

riakcmd(Node, Cmd) ->
    node_path(Node) ++ "/bin/riak " ++ Cmd.

gitcmd(Path, Cmd) ->
    io_lib:format("git --git-dir=\"~s/.git\" --work-tree=\"~s/\" ~s",
                  [Path, Path, Cmd]).

riak_admin_cmd(Node, Args) ->
    Quoted =
        lists:map(fun(Arg) when is_list(Arg) ->
                          lists:flatten([$", Arg, $"]);
                     (_) ->
                          erlang:error(badarg)
                  end, Args),
    ArgStr = string:join(Quoted, " "),
    node_path(Node) ++ "/bin/riak-admin " ++ ArgStr.

load_hosts() ->
    {HostsIn, Aliases} = read_hosts_file("hosts"),
    Hosts = lists:sort(HostsIn),
    rt_config:set(rtssh_hosts, Hosts),
    rt_config:set(rtssh_aliases, Aliases),
    Hosts.

read_hosts_file(File) ->
    case file:consult(File) of
        {ok, Terms} ->
            lists:mapfoldl(fun({Alias, Host}, Aliases) ->
                                   Aliases2 = orddict:store(Host, Host, Aliases),
                                   Aliases3 = orddict:store(Alias, Host, Aliases2),
                                   {Host, Aliases3};
                              (Host, Aliases) ->
                                   Aliases2 = orddict:store(Host, Host, Aliases),
                                   {Host, Aliases2}
                           end, orddict:new(), Terms);
        _ ->
            erlang:error({"Missing or invalid rtssh hosts file", file:get_cwd()})
    end.

get_host(Node) ->
    orddict:fetch(Node, rt_config:get(rt_hosts)).

%%%===================================================================
%%% Remote file operations
%%%===================================================================

wildcard(Node, Path) ->
    Cmd = "find " ++ Path ++ " -maxdepth 0 -print",
    case ssh_cmd(Node, Cmd) of
        {0, Result} ->
            string:tokens(Result, "\n");
        _ ->
            error
    end.

spawn_ssh_cmd(Node, Cmd) ->

    spawn_ssh_cmd(Node, Cmd, []).

spawn_ssh_cmd(Node, Cmd, Opts) when is_atom(Node) ->
    Host = get_host(Node),
    lager:info("node to host translation ~p -> ~p", [Node, Host]),
    spawn_ssh_cmd(Host, Cmd, Opts, true);
spawn_ssh_cmd(Host, Cmd, Opts) ->
    spawn_ssh_cmd(Host, Cmd, Opts, true).

spawn_ssh_cmd(Node, Cmd, Opts, Return) when is_atom(Node) ->
    Host = get_host(Node),
    spawn_ssh_cmd(Host, Cmd, Opts, Return);
spawn_ssh_cmd(Host, Cmd, Opts, Return) ->
    Quiet =
    case Return of
        true -> "";
        false -> " > /dev/null 2>&1"
    end,
    SSHCmd = format("ssh -q -o 'StrictHostKeyChecking no' ~s '~s'"++Quiet,
            [Host, Cmd]),
    spawn_cmd(SSHCmd, Opts).

ssh_cmd(Node, Cmd) ->
    ssh_cmd(Node, Cmd, true).

ssh_cmd(Node, Cmd, Return) ->
    wait_for_cmd(spawn_ssh_cmd(Node, Cmd, [stderr_to_stdout], Return)).

remote_read_file(Node, File) ->
    case ssh_cmd(Node, "cat " ++ File) of
        {0, Text} ->
            %% io:format("~p/~p: read: ~p~n", [Node, File, Text]),

            %% Note: remote_read_file sometimes returns "" for some
            %% reason, however printing out to debug things (as in the
            %% above io:format) makes error go away. Going to assume
            %% race condition and throw in timer:sleep here.
            %% TODO: debug for real.
            timer:sleep(500),
            list_to_binary(Text);
        Error ->
            erlang:error("Failed to read remote file", [Node, File, Error])
    end.

remote_write_file(NodeOrHost, File, Data) ->
    Port = spawn_ssh_cmd(NodeOrHost, "cat > " ++ File, [out]),
    true = port_command(Port, Data),
    true = port_close(Port),
    ok.

format(Msg, Args) ->
    lists:flatten(io_lib:format(Msg, Args)).

update_vm_args(_Node, []) ->
    ok;
update_vm_args(Node, Props) ->
    VMArgs = node_path(Node) ++ "/etc/vm.args",
    Bin = remote_read_file(Node, VMArgs),
    Output =
        lists:foldl(fun({Config, Value}, Acc) ->
                            CBin = to_binary(Config),
                            VBin = to_binary(Value),
                            case re:replace(Acc,
                                            <<"((^|\\n)", CBin/binary, ").+\\n">>,
                                            <<"\\1 ", VBin/binary, $\n>>) of
                                CBin -> <<CBin/binary, VBin/binary, $\n>>;
                                Mod -> Mod
                            end
                    end, Bin, Props),
    %% io:format("~p~n", [iolist_to_binary(Output)]),
    remote_write_file(Node, VMArgs, Output),
    ok.


host_from_node(Node) ->
    NodeName = atom_to_list(Node),
    lists:nth(2, string:tokens(NodeName, "@")).

update_app_config(Node0, Config) ->
    ConfigFile = node_path(Node0) ++ "/etc/app.config",
    Node = host_from_node(Node0),
    update_app_config_file(Node, ConfigFile, Config).

update_app_config_file(Node, ConfigFile, Config) ->
    %% lager:info("rtssh:update_app_config_file(~p, ~s, ~p)",
    %%            [Node, ConfigFile, Config]),
    Bin = remote_read_file(Node, ConfigFile),
    BaseConfig =
        try
            {ok, BC} = consult_string(Bin),
            BC
        catch
            _:_ ->
                erlang:error({"Failed to parse app.config for", Node, Bin})
        end,
    %% io:format("BaseConfig: ~p~n", [BaseConfig]),
    MergeA = orddict:from_list(Config),
    MergeB = orddict:from_list(BaseConfig),
    NewConfig =
        orddict:merge(fun(_, VarsA, VarsB) ->
                              MergeC = orddict:from_list(VarsA),
                              MergeD = orddict:from_list(VarsB),
                              Props =
                                  orddict:merge(fun(_, Fun, ValB) when is_function(Fun) ->
                                                        Fun(ValB);
                                                   (_, ValA, _ValB) ->
                                                        ValA
                                                end, MergeC, MergeD),
                              [{K,V} || {K,V} <- Props,
                                        not is_function(V)]
                      end, MergeA, MergeB),
    NewConfigOut = io_lib:format("~p.", [NewConfig]),
    ?assertEqual(ok, remote_write_file(Node, ConfigFile, NewConfigOut)),
    ok.

-spec set_conf(atom() | string(), [{string(), string()}]) -> ok.
%% set_conf(all, NameValuePairs) ->
%%     lager:info("rtdev:set_conf(all, ~p)", [NameValuePairs]),
%%     [ set_conf(DevPath, NameValuePairs) || DevPath <- devpaths()],
%%     ok;
set_conf(Node0, NameValuePairs) when is_atom(Node0) ->
    Node = host_from_node(Node0),
    Path = node_path(Node0) ++ "/etc/riak.conf",
    append_to_conf_file(Node,
                        Path,
                        remote_read_file(Node, Path),
                        NameValuePairs),
    ok.%% ;
%% set_conf(DevPath, NameValuePairs) ->
%%     [append_to_conf_file(RiakConf, NameValuePairs)
%%      || RiakConf <- all_the_files(DevPath, "etc/riak.conf")],
%%     ok.

all_the_files(DevPath, File) ->
    case filelib:is_dir(DevPath) of
        true ->
            Wildcard = io_lib:format("~s/dev/dev*/~s", [DevPath, File]),
            filelib:wildcard(Wildcard);
        _ ->
            lager:debug("~s is not a directory.", [DevPath]),
            []
    end.


%% get_riak_conf(Node) ->
%%     Path = relpath(node_version(N)),
%%     io_lib:format("~s/dev/dev~b/etc/riak.conf", [Path, N]).

append_to_conf_file(Node, Path, File, NameValuePairs) ->
    Settings = lists:flatten(
                 [begin
                      Name =
                          case Name0 of
                              N when is_atom(N) ->
                                  atom_to_list(N);
                              _ ->
                                  Name0
                          end,
                      Value =
                          case Value0 of
                              V when is_atom(V) ->
                                  atom_to_list(V);
                              V when is_integer(V) ->
                                  integer_to_list(V);
                              _ ->
                                  Value0
                          end,
                      io_lib:format("~n~s = ~s~n", [Name, Value])
                  end
                  || {Name0, Value0} <- NameValuePairs]),
    remote_write_file(Node, Path, iolist_to_binary([File]++Settings)).

consult_string(Bin) when is_binary(Bin) ->
    consult_string(binary_to_list(Bin));
consult_string(Str) ->
    {ok, Tokens, _} = erl_scan:string(Str),
    erl_parse:parse_term(Tokens).


ensure_remote_build(Hosts, Version) ->
    lager:info("Ensuring remote build: ~p", [Version]),
    %%lager:info("~p ~n ~p", [Version, Hosts]),
    Base = rt_config:get(perf_builds),
    Dir = Base++"/"++Version++"/",
    lager:info("Using build at ~p", [Dir]),
    {ok, Info} = file:read_file_info(Dir),
    ?assertEqual(directory, Info#file_info.type),
    Sum =
        case os:cmd("dir_sum.sh "++Dir) of
            [] ->
                throw("error runing dir validator");
            S -> S
        end,

    F = fun(Host) ->
                case ssh_cmd(Host, "~/bin/dir_sum.sh "++Dir) of
                    {0, Sum} -> ok;
                    {2, []} ->
                        {0, _} = deploy_build(Host, Dir),
                        {0, Sum} = ssh_cmd(Host, "~/bin/dir_sum.sh "++Dir);
                    {0, OtherSum} ->
                        error("Bad build on host "++Host++" with sum "++OtherSum)
                end,
                lager:info("Build OK on host: ~p", [Host]),
                {0, _} = ssh_cmd(Host, "rm -rf "++Dir++"/data/*"),
                {0, _} = ssh_cmd(Host, "mkdir -p "++Dir++"/data/snmp/agent/db/"),
                {0, _} = ssh_cmd(Host, "rm -rf "++Dir++"/log/*"),
                lager:info("Cleaned up host ~p", [Host])
        end,
    rt:pmap(F, Hosts),
    %% if we get here, we need to reset rtdev path, because we're not
    %% using it as defined.
    rt_config:set(rtdev_path, [{root, Base}, {Version, Dir}]),
    ok.


scp(Host, Path, RemotePath) ->
    ssh_cmd(Host, "mkdir -p "++RemotePath),
    SCP = format("scp -qr -o 'StrictHostKeyChecking no' ~s ~s:~s",
                 [Path, Host, RemotePath]),
    %%lager:info("SCP ~p", [SCP]),
    wait_for_cmd(spawn_cmd(SCP)).

deploy_build(Host, Dir) ->
    ssh_cmd(Host, "mkdir -p "++Dir),
    Base0 = filename:split(Dir),
    Base1 = lists:delete(lists:last(Base0), Base0),
    Base = filename:join(Base1),
    SCP = format("scp -qr -o 'StrictHostKeyChecking no' ~s ~s:~s",
                 [Dir, Host, Base]),
    %%lager:info("SCP ~p", [SCP]),
    wait_for_cmd(spawn_cmd(SCP)).

%%%===================================================================
%%% Riak devrel path utilities
%%%===================================================================

-define(PATH, (rt_config:get(rtdev_path))).

dev_path(Path, N) ->
    format("~s/dev/dev~b", [Path, N]).

dev_bin_path(Path, N) ->
    dev_path(Path, N) ++ "/bin".

dev_etc_path(Path, N) ->
    dev_path(Path, N) ++ "/etc".

dev_data_path(Path, N) ->
    dev_path(Path, N) ++ "/data".

relpath(Vsn) ->
    Path = ?PATH,
    relpath(Vsn, Path).

relpath(Vsn, Paths=[{_,_}|_]) ->
    orddict:fetch(Vsn, orddict:from_list(Paths));
relpath(current, Path) ->
    Path;
relpath(root, Path) ->
    Path;
relpath(What, _) ->
    throw(What).
%%    throw("Version requested but only one path provided").

node_path(Node) ->
    %%N = node_id(Node),
    relpath(node_version(Node)).
    %%lists:flatten(io_lib:format("~s/dev/dev~b", [Path, N])).

node_id(_Node) ->
    %% NodeMap = rt_config:get(rt_nodes),
    %% orddict:fetch(Node, NodeMap).
    1.

node_version(Node) ->
    orddict:fetch(Node, rt_config:get(rt_versions)).

%%%===================================================================
%%% Local command spawning
%%%===================================================================

spawn_cmd(Cmd) ->
    spawn_cmd(Cmd, []).
spawn_cmd(Cmd, Opts) ->
    Port = open_port({spawn, Cmd}, [stream, in, exit_status] ++ Opts),
    put(Port, Cmd),
    Port.

wait_for_cmd(Port) ->
    rt:wait_until(node(),
                  fun(_) ->
              %%lager:info("waiting until"),
                          receive
                              {Port, Msg={data, _}} ->
                  %%lager:info("got data ~p", [Msg]),
                                  self() ! {Port, Msg},
                                  false;
                              {Port, Msg={exit_status, _}} ->
                  %%lager:info("got exit"),
                                  catch port_close(Port),
                                  self() ! {Port, Msg},
                                  true
              after 0 ->
                  %%lager:info("timed out"),
                  false
                          end
                  end),
    get_cmd_result(Port, []).

get_cmd_result(Port, Acc) ->
    receive
        {Port, {data, Bytes}} ->
        %%lager:info("got bytes: ~p", [Bytes]),
        get_cmd_result(Port, [Bytes|Acc]);
        {Port, {exit_status, Status}} ->
            case Status of
                0 -> ok;
                _ ->
                    Cmd = get(Port),
                    lager:info("~p returned exit status: ~p",
                               [Cmd, Status])
            end,
            erase(Port),
            Output = lists:flatten(lists:reverse(Acc)),
            {Status, Output}
    %% after 0 ->
    %%         error(timeout)
    end.

%%%===================================================================
%%% rtdev stuff
%%%===================================================================

devpaths() ->
    Paths = proplists:delete(root, rt_config:get(rtdev_path)),
    lists:usort([DevPath || {_Name, DevPath} <- Paths]).

%% in the perf case, we don't always (or even usually) want to stop
maybe_stop_all(Hosts) ->
    case rt_config:get(perf_restart, meh) of
        true ->
            F = fun(Host) ->
                        lager:info("Checking host ~p for running riaks",
                                   [Host]),
                        Cmd = "ps aux | grep beam.sm[p] | awk \"{ print \\$11 }\"",
                        {0, Dirs} = ssh_cmd(Host, Cmd),
                        %% lager:info("Dirs ~p", [Dirs]),
                        DirList = string:tokens(Dirs, "\n"),
                        lists:foreach(
                              fun(Dir) ->
                                      Path = lists:nth(1, string:tokens(Dir, ".")),
                                      lager:info("Detected running riak at: ~p",
                                                 [Path]),
                                      %% not really safe, but fast and effective.
                                      _ = ssh_cmd(Host, "killall beam.smp")
                              end, DirList)
                end,
            rt:pmap(F, Hosts);
        _ -> ok
    end.


stop_all(Hosts) ->
    %% [stop_all(Host, DevPath ++ "/dev") || Host <- Hosts,
    %%                                       DevPath <- devpaths()].
    All = [{Host, DevPath} || Host <- Hosts,
                              DevPath <- devpaths()],
    rt:pmap(fun({Host, DevPath}) ->
                    stop_all(Host, DevPath ++ "/dev")
            end, All).

stop_all(Host, DevPath) ->
    case wildcard(Host, DevPath ++ "/dev*") of
        error ->
            lager:info("~s is not a directory.", [DevPath]);
        Devs ->
            [begin
                 Cmd = D ++ "/bin/riak stop",
                 {_, Result} = ssh_cmd(Host, Cmd),
                 [Output | _Tail] = string:tokens(Result, "\n"),
                 Status = case Output of
                              "ok" -> "ok";
                              _ -> "wasn't running"
                          end,
                 lager:info("Stopping Node... ~s :: ~s ~~ ~s.",
                            [Host, Cmd, Status])
             end || D <- Devs]
    end,
    ok.

teardown() ->
    case rt_config:get(perf_restart, meh) of
        true ->
            stop_all(rt_config:get(rt_hostnames));
        _  ->
            ok
    end.

%%%===================================================================
%%% Utilities
%%%===================================================================

to_list(X) when is_integer(X) -> integer_to_list(X);
to_list(X) when is_float(X)   -> float_to_list(X);
to_list(X) when is_atom(X)    -> atom_to_list(X);
to_list(X) when is_list(X)    -> X.	%Assumed to be a string

to_binary(X) when is_binary(X) ->
    X;
to_binary(X) ->
    list_to_binary(to_list(X)).
