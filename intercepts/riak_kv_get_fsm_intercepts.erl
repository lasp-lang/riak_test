-module(riak_kv_get_fsm_intercepts).
-compile(export_all).
-include("intercept.hrl").
-define(M, riak_kv_get_fsm_orig).

count_start_link_4(From, Bucket, Key, GetOptions) ->
    ?I_INFO("sending startlink/4 through proxy"),
    case ?M:start_link_orig(From, Bucket, Key, GetOptions) of
        {error, overload} ->
            ?I_INFO("riak_kv_get_fsm not started due to overload.");
        {ok, _} ->
            gen_server:cast({global, overload_proxy}, increment_count)
    end.

%% @doc simulate slow puts by adding delay to the prepare state.
slow_prepare(Atom, State) ->
    timer:sleep(1000),
    ?M:prepare_orig(Atom, State).
