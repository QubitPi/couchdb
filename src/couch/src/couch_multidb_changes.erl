% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_multidb_changes).

-behaviour(gen_server).

-export([
    start_link/4
]).

-export([
    init/1,
    terminate/2,
    handle_call/3,
    handle_info/2,
    handle_cast/2
]).

-export([
    changes_reader/3,
    changes_reader_cb/3
]).

-include_lib("couch/include/couch_db.hrl").
-include_lib("mem3/include/mem3.hrl").

-define(CTX, {user_ctx, #user_ctx{roles = [<<"_admin">>, <<"_replicator">>]}}).

-define(AVG_DELAY_MSEC, 10).
-define(MAX_DELAY_MSEC, 120000).

-record(state, {
    tid :: ets:tid(),
    mod :: atom(),
    ctx :: term(),
    suffix :: binary(),
    event_server :: reference(),
    scanner :: nil | pid(),
    pids :: #{},
    skip_ddocs :: boolean()
}).

% Behavior API

% For each db shard with a matching suffix, report created,
% deleted, found (discovered) and change events.

-callback db_created(DbName :: binary(), Context :: term()) ->
    Context :: term().

-callback db_deleted(DbName :: binary(), Context :: term()) ->
    Context :: term().

-callback db_found(DbName :: binary(), Context :: term()) ->
    Context :: term().

-callback db_change(DbName :: binary(), Change :: term(), Context :: term()) ->
    Context :: term().

% External API

% Opts list can contain:
%  - `skip_ddocs` : Skip design docs

-spec start_link(binary(), module(), term(), list()) ->
    {ok, pid()} | ignore | {error, term()}.
start_link(DbSuffix, Module, Context, Opts) when
    is_binary(DbSuffix), is_atom(Module), is_list(Opts)
->
    gen_server:start_link(?MODULE, [DbSuffix, Module, Context, Opts], []).

% gen_server callbacks

init([DbSuffix, Module, Context, Opts]) ->
    process_flag(trap_exit, true),
    Server = self(),
    {ok, #state{
        tid = ets:new(?MODULE, [set, public]),
        mod = Module,
        ctx = Context,
        suffix = DbSuffix,
        event_server = register_with_event_server(Server),
        scanner = spawn_link(fun() -> scan_all_dbs(Server, DbSuffix) end),
        pids = #{},
        skip_ddocs = proplists:is_defined(skip_ddocs, Opts)
    }}.

terminate(_Reason, _State) ->
    ok.

handle_call({change, DbName, Change}, _From, #state{} = State) ->
    #state{skip_ddocs = SkipDDocs, mod = Mod, ctx = Ctx} = State,
    case {SkipDDocs, is_design_doc(Change)} of
        {true, true} ->
            {reply, ok, State};
        {_, _} ->
            {reply, ok, State#state{ctx = Mod:db_change(DbName, Change, Ctx)}}
    end;
handle_call({checkpoint, DbName, EndSeq}, {Pid, _Tag} = _From, #state{tid = Ets} = State) ->
    case ets:lookup(Ets, DbName) of
        [{DbName, _OldSeq, Rescan, Pid}] ->
            true = ets:insert(Ets, {DbName, EndSeq, Rescan, Pid});
        _ ->
            % Ignore stale checkpoints or checkpoints from unknown change feeds
            ok
    end,
    {reply, ok, State}.

handle_cast({resume_scan, DbName}, State) ->
    {noreply, resume_scan(DbName, State)}.

handle_info({'$couch_event', DbName, Event}, #state{suffix = Suf} = State) ->
    case Suf =:= couch_db:dbname_suffix(DbName) of
        true ->
            {noreply, db_callback(Event, DbName, State)};
        _ ->
            {noreply, State}
    end;
handle_info({'DOWN', Ref, _, _, Info}, #state{event_server = Ref} = State) ->
    {stop, {couch_event_server_died, Info}, State};
handle_info({'EXIT', From, normal}, #state{scanner = From} = State) ->
    {noreply, State#state{scanner = nil}};
handle_info({'EXIT', From, Reason}, #state{scanner = From} = State) ->
    {stop, {scanner_died, Reason}, State};
handle_info({'EXIT', From, Reason}, #state{pids = #{} = Pids} = State) ->
    couch_log:debug("~p change feed exited ~p", [State#state.suffix, From]),
    case maps:take(From, Pids) of
        {DbName, NewPids} ->
            if
                Reason == normal ->
                    ok;
                true ->
                    Fmt = "~s : Known change feed ~w died :: ~w",
                    couch_log:error(Fmt, [?MODULE, From, Reason])
            end,
            NewState = State#state{pids = NewPids},
            case ets:lookup(State#state.tid, DbName) of
                [{DbName, _EndSeq, true, From}] ->
                    % Match the From pid explicitly and then clear it
                    % The pid is at 4th position in the ets object
                    ets:update_element(NewState#state.tid, DbName, {4, undefined}),
                    {noreply, resume_scan(DbName, NewState)};
                [{DbName, _EndSeq, false, From}] ->
                    ets:update_element(NewState#state.tid, DbName, {4, undefined}),
                    {noreply, NewState};
                _ ->
                    {noreply, NewState}
            end;
        error ->
            Fmt = "~s(~p) : Unknown pid ~w died :: ~w",
            couch_log:error(Fmt, [?MODULE, State#state.suffix, From, Reason]),
            {stop, {unexpected_exit, From, Reason}, State}
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

% Private functions

-spec register_with_event_server(pid()) -> reference().
register_with_event_server(Server) ->
    Ref = erlang:monitor(process, couch_event_server),
    couch_event:register_all(Server),
    Ref.

-spec db_callback(created | deleted | updated, binary(), #state{}) -> #state{}.
db_callback(created, DbName, #state{mod = Mod, ctx = Ctx} = State) ->
    NewState = State#state{ctx = Mod:db_created(DbName, Ctx)},
    resume_scan(DbName, NewState);
db_callback(deleted, DbName, #state{mod = Mod, ctx = Ctx} = State) ->
    State#state{ctx = Mod:db_deleted(DbName, Ctx)};
db_callback(updated, DbName, State) ->
    resume_scan(DbName, State);
db_callback(_Other, _DbName, State) ->
    State.

-spec resume_scan(binary(), #state{}) -> #state{}.
resume_scan(DbName, #state{pids = #{} = Pids, tid = Ets} = State) ->
    case ets:lookup(Ets, DbName) of
        [{DbName, EndSeq, _, undefined}] ->
            % No existing change feed running. Found existing checkpoint.
            % Start a new change reader from last checkpoint.
            Pid = start_changes_reader(DbName, EndSeq),
            true = ets:insert(Ets, {DbName, EndSeq, false, Pid}),
            State#state{pids = Pids#{Pid => DbName}};
        [{DbName, EndSeq, _, Pid}] ->
            % Found existing change feed and entry in ETS
            % Flag a need to rescan from last ETS checkpoint
            true = ets:insert(Ets, {DbName, EndSeq, true, Pid}),
            State;
        [] ->
            % No entry in ETS. This is first time seeing this db shard. Notify
            % user with a found callback. Insert checkpoint entry in ETS to
            % start from 0. And start a change feed.
            Pid = start_changes_reader(DbName, 0),
            true = ets:insert(Ets, {DbName, 0, false, Pid}),
            Mod = State#state.mod,
            Ctx = Mod:db_found(DbName, State#state.ctx),
            State#state{ctx = Ctx, pids = Pids#{Pid => DbName}}
    end.

start_changes_reader(DbName, Since) ->
    spawn_link(?MODULE, changes_reader, [self(), DbName, Since]).

changes_reader(Server, DbName, Since) ->
    {ok, Db} = couch_db:open_int(DbName, [?CTX, sys_db]),
    ChangesArgs = #changes_args{
        include_docs = true,
        since = Since,
        feed = "normal",
        timeout = infinity
    },
    ChFun = couch_changes:handle_db_changes(ChangesArgs, {json_req, null}, Db),
    ChFun({fun ?MODULE:changes_reader_cb/3, {Server, DbName}}).

changes_reader_cb({change, Change, _}, _, {Server, DbName}) ->
    ok = gen_server:call(Server, {change, DbName, Change}, infinity),
    {Server, DbName};
changes_reader_cb({stop, EndSeq}, _, {Server, DbName}) ->
    ok = gen_server:call(Server, {checkpoint, DbName, EndSeq}, infinity),
    {Server, DbName};
changes_reader_cb(_, _, Acc) ->
    Acc.

scan_all_dbs(Server, DbSuffix) when is_pid(Server) ->
    ok = scan_local_db(Server, DbSuffix),
    {ok, Db} = mem3_util:ensure_exists(shards_db()),
    ChangesFun = couch_changes:handle_db_changes(#changes_args{}, nil, Db),
    ChangesFun({fun scan_changes_cb/3, {Server, DbSuffix, 1}}),
    couch_db:close(Db).

scan_changes_cb({change, {Change}, _}, _, {_Server, DbSuffix, _Count} = Acc) ->
    DbName = couch_util:get_value(<<"id">>, Change),
    case DbName of
        <<"_design/", _/binary>> ->
            Acc;
        _Else ->
            NameMatch = DbSuffix =:= couch_db:dbname_suffix(DbName),
            case {NameMatch, is_deleted(Change)} of
                {false, _} ->
                    Acc;
                {true, true} ->
                    Acc;
                {true, false} ->
                    Shards = local_shards(DbName),
                    lists:foldl(fun notify_fold/2, Acc, Shards)
            end
    end;
scan_changes_cb(_, _, Acc) ->
    Acc.

is_deleted(Change) ->
    couch_util:get_value(<<"deleted">>, Change, false).

shards_db() ->
    config:get("mem3", "shards_db", "_dbs").

local_shards(DbName) ->
    try
        [ShardName || #shard{name = ShardName} <- mem3:local_shards(DbName)]
    catch
        error:database_does_not_exist ->
            []
    end.

notify_fold(DbName, {Server, DbSuffix, Count}) ->
    Jitter = jitter(Count),
    spawn_link(fun() ->
        timer:sleep(Jitter),
        gen_server:cast(Server, {resume_scan, DbName})
    end),
    {Server, DbSuffix, Count + 1}.

% Jitter is proportional to the number of shards found so far. This is done to
% avoid a stampede and notifying the callback function with potentially a large
% number of shards back to back during startup.
jitter(N) ->
    Range = min(2 * N * ?AVG_DELAY_MSEC, ?MAX_DELAY_MSEC),
    couch_rand:uniform(Range).

scan_local_db(Server, DbSuffix) when is_pid(Server) ->
    case couch_server:exists(DbSuffix) of
        true -> gen_server:cast(Server, {resume_scan, DbSuffix});
        false -> ok
    end.

is_design_doc({Change}) ->
    case lists:keyfind(<<"id">>, 1, Change) of
        false ->
            false;
        {_, Id} ->
            is_design_doc_id(Id)
    end.

is_design_doc_id(<<?DESIGN_DOC_PREFIX, _/binary>>) ->
    true;
is_design_doc_id(_) ->
    false.

-ifdef(TEST).

-include_lib("couch/include/couch_eunit.hrl").

-define(MOD, multidb_test_module).
-define(SUFFIX, <<"suff">>).
-define(DBNAME, <<"shards/40000000-5fffffff/acct/suff.0123456789">>).

couch_multidb_changes_test_() ->
    {
        setup,
        fun setup_all/0,
        fun teardown_all/1,
        {
            foreach,
            fun setup/0,
            fun teardown/1,
            [
                ?TDEF_FE(t_handle_call_change),
                ?TDEF_FE(t_handle_call_change_filter_design_docs),
                ?TDEF_FE(t_handle_call_checkpoint_new),
                ?TDEF_FE(t_handle_call_checkpoint_existing),
                ?TDEF_FE(t_handle_call_checkpoint_stale_changes_pid),
                ?TDEF_FE(t_handle_info_created),
                ?TDEF_FE(t_handle_info_deleted),
                ?TDEF_FE(t_handle_info_updated),
                ?TDEF_FE(t_handle_info_other_event),
                ?TDEF_FE(t_handle_info_created_other_db),
                ?TDEF_FE(t_handle_info_scanner_exit_normal),
                ?TDEF_FE(t_handle_info_scanner_crashed),
                ?TDEF_FE(t_handle_info_event_server_exited),
                ?TDEF_FE(t_handle_info_unknown_pid_exited),
                ?TDEF_FE(t_handle_info_change_feed_exited),
                ?TDEF_FE(t_handle_info_change_feed_exited_and_need_rescan),
                ?TDEF_FE(t_spawn_changes_reader),
                ?TDEF_FE(t_changes_reader_cb_change),
                ?TDEF_FE(t_changes_reader_cb_stop),
                ?TDEF_FE(t_changes_reader_cb_other),
                ?TDEF_FE(t_handle_call_resume_scan_no_chfeed_no_ets_entry),
                ?TDEF_FE(t_handle_call_resume_scan_chfeed_no_ets_entry),
                ?TDEF_FE(t_handle_call_resume_scan_chfeed_ets_entry),
                ?TDEF_FE(t_handle_call_resume_scan_no_chfeed_ets_entry),
                ?TDEF_FE(t_start_link),
                ?TDEF_FE(t_start_link_no_ddocs),
                ?TDEF_FE(t_misc_gen_server_callbacks)
            ]
        }
    }.

setup_all() ->
    mock_logs(),
    mock_callback_mod(),
    meck:expect(couch_event, register_all, 1, ok),
    test_util:start_applications([config]),
    meck:expect(mem3_util, ensure_exists, 1, {ok, dbs}),
    ChangesFun = meck:val(fun(_) -> ok end),
    meck:expect(couch_changes, handle_db_changes, 3, ChangesFun),
    meck:expect(
        couch_db,
        open_int,
        fun
            (?DBNAME, [?CTX, sys_db]) -> {ok, db};
            (_, _) -> {not_found, no_db_file}
        end
    ),
    meck:expect(couch_db, close, 1, ok),
    mock_changes_reader(),
    % create process to stand in for couch_event_server
    % mocking erlang:monitor doesn't work, so give it real process to monitor
    EvtPid = spawn_link(fun() ->
        receive
            looper -> ok
        end
    end),
    true = register(couch_event_server, EvtPid),
    EvtPid.

teardown_all(EvtPid) ->
    test_util:stop_applications([config]),
    unlink(EvtPid),
    exit(EvtPid, kill),
    meck:unload().

setup() ->
    meck:reset([
        ?MOD,
        couch_changes,
        couch_db,
        couch_event,
        couch_log
    ]).

teardown(_) ->
    ok.

t_handle_call_change(_) ->
    State = mock_state(),
    Change = change_row(<<"blah">>),
    handle_call_ok({change, ?DBNAME, Change}, State),
    ?assert(meck:validate(?MOD)),
    ?assert(meck:called(?MOD, db_change, [?DBNAME, Change, zig])).

t_handle_call_change_filter_design_docs(_) ->
    State0 = mock_state(),
    State = State0#state{skip_ddocs = true},
    Change = change_row(<<"_design/blah">>),
    handle_call_ok({change, ?DBNAME, Change}, State),
    ?assert(meck:validate(?MOD)),
    ?assertNot(meck:called(?MOD, db_change, [?DBNAME, Change, zig])).

t_handle_call_checkpoint_new(_) ->
    Tid = mock_ets(),
    State = mock_state(Tid, cpid),
    handle_call_ok({checkpoint, ?DBNAME, 1}, cpid, State),
    ?assertEqual([{?DBNAME, 1, false, cpid}], ets:tab2list(Tid)),
    ets:delete(Tid).

t_handle_call_checkpoint_existing(_) ->
    Tid = mock_ets(),
    State = mock_state(Tid, cpid),
    handle_call_ok({checkpoint, ?DBNAME, 2}, cpid, State),
    ?assertEqual([{?DBNAME, 2, false, cpid}], ets:tab2list(Tid)),
    ets:delete(Tid).

t_handle_call_checkpoint_stale_changes_pid(_) ->
    Tid = mock_ets(),
    State = mock_state(Tid, cpid),
    handle_call_ok({checkpoint, ?DBNAME, 42}, other, State),
    ?assertEqual([{?DBNAME, 0, false, cpid}], ets:tab2list(Tid)),
    ets:delete(Tid).

t_handle_info_created(_) ->
    Tid = mock_ets(),
    State = mock_state(Tid),
    handle_info_check({'$couch_event', ?DBNAME, created}, State),
    ?assert(meck:validate(?MOD)),
    ?assert(meck:called(?MOD, db_created, [?DBNAME, zig])).

t_handle_info_deleted(_) ->
    State = mock_state(),
    handle_info_check({'$couch_event', ?DBNAME, deleted}, State),
    ?assert(meck:validate(?MOD)),
    ?assert(meck:called(?MOD, db_deleted, [?DBNAME, zig])).

t_handle_info_updated(_) ->
    Tid = mock_ets(),
    State = mock_state(Tid),
    handle_info_check({'$couch_event', ?DBNAME, updated}, State),
    ?assert(meck:validate(?MOD)),
    ?assert(meck:called(?MOD, db_found, [?DBNAME, zig])).

t_handle_info_other_event(_) ->
    State = mock_state(),
    handle_info_check({'$couch_event', ?DBNAME, somethingelse}, State),
    ?assertNot(meck:called(?MOD, db_created, [?DBNAME, somethingelse])),
    ?assertNot(meck:called(?MOD, db_deleted, [?DBNAME, somethingelse])),
    ?assertNot(meck:called(?MOD, db_found, [?DBNAME, somethingelse])).

t_handle_info_created_other_db(_) ->
    State = mock_state(),
    handle_info_check({'$couch_event', <<"otherdb">>, created}, State),
    ?assertNot(meck:called(?MOD, db_created, [?DBNAME, zig])).

t_handle_info_scanner_exit_normal(_) ->
    Res = handle_info({'EXIT', spid, normal}, mock_state()),
    ?assertMatch({noreply, _}, Res),
    {noreply, RState} = Res,
    ?assertEqual(nil, RState#state.scanner).

t_handle_info_scanner_crashed(_) ->
    Res = handle_info({'EXIT', spid, oops}, mock_state()),
    ?assertMatch({stop, {scanner_died, oops}, _State}, Res).

t_handle_info_event_server_exited(_) ->
    Res = handle_info({'DOWN', esref, type, espid, reason}, mock_state()),
    ?assertMatch({stop, {couch_event_server_died, reason}, _}, Res).

t_handle_info_unknown_pid_exited(_) ->
    State0 = mock_state(),
    Res0 = handle_info({'EXIT', somepid, normal}, State0),
    ?assertMatch({stop, {unexpected_exit, somepid, normal}, State0}, Res0),
    State1 = mock_state(),
    Res1 = handle_info({'EXIT', somepid, oops}, State1),
    ?assertMatch({stop, {unexpected_exit, somepid, oops}, State1}, Res1).

t_handle_info_change_feed_exited(_) ->
    Tid0 = mock_ets(),
    State0 = mock_state(Tid0, cpid),
    Res0 = handle_info({'EXIT', cpid, normal}, State0),
    ?assertMatch({noreply, _}, Res0),
    {noreply, RState0} = Res0,
    ?assertEqual(#{}, RState0#state.pids),
    ets:delete(Tid0),
    Tid1 = mock_ets(),
    State1 = mock_state(Tid1, cpid),
    Res1 = handle_info({'EXIT', cpid, oops}, State1),
    ?assertMatch({noreply, _}, Res1),
    {noreply, RState1} = Res1,
    ?assertEqual(#{}, RState1#state.pids),
    ets:delete(Tid1).

t_handle_info_change_feed_exited_and_need_rescan(_) ->
    Tid = mock_ets(),
    State = mock_state(Tid, cpid),
    true = ets:insert(Tid, {?DBNAME, 1, true, cpid}),
    Res = handle_info({'EXIT', cpid, normal}, State),
    ?assertMatch({noreply, _}, Res),
    {noreply, RState} = Res,
    % a mock change feed process should be running
    [{Pid, ?DBNAME}] = maps:to_list(RState#state.pids),
    ?assert(is_pid(Pid)),
    % rescan flag should have been reset to false
    ?assertEqual([{?DBNAME, 1, false, Pid}], ets:tab2list(Tid)),
    ChArgs = kill_mock_changes_reader_and_get_its_args(Pid),
    ?assertEqual({self(), ?DBNAME}, ChArgs),
    ets:delete(Tid).

t_spawn_changes_reader(_) ->
    Pid = start_changes_reader(?DBNAME, 3),
    ?assert(erlang:is_process_alive(Pid)),
    ChArgs = kill_mock_changes_reader_and_get_its_args(Pid),
    ?assertEqual({self(), ?DBNAME}, ChArgs),
    ?assert(meck:validate(couch_db)),
    ?assert(meck:validate(couch_changes)),
    ?assert(meck:called(couch_db, open_int, [?DBNAME, [?CTX, sys_db]])),
    ?assert(
        meck:called(couch_changes, handle_db_changes, [
            #changes_args{
                include_docs = true,
                since = 3,
                feed = "normal",
                timeout = infinity
            },
            {json_req, null},
            db
        ])
    ).

t_changes_reader_cb_change(_) ->
    {ok, Pid} = start_link(?SUFFIX, ?MOD, zig, []),
    Change = change_row(<<"blah">>),
    ChArg = {change, Change, ignore},
    {Pid, ?DBNAME} = changes_reader_cb(ChArg, chtype, {Pid, ?DBNAME}),
    ?assert(meck:called(?MOD, db_change, [?DBNAME, Change, zig])),
    unlink(Pid),
    exit(Pid, kill).

t_changes_reader_cb_stop(_) ->
    {ok, ServerPid} = start_link(?SUFFIX, ?MOD, zig, []),
    #state{tid = Tid} = sys:get_state(ServerPid),
    ChPid = self(),
    ets:insert(Tid, {?DBNAME, 1, false, ChPid}),
    sys:replace_state(ServerPid, fun(#state{} = OldSt) ->
        OldSt#state{pids = #{ChPid => ?DBNAME}}
    end),
    ChArg = {stop, 11},
    {ServerPid, ?DBNAME} = changes_reader_cb(ChArg, chtype, {ServerPid, ?DBNAME}),
    % We checkpoint on stop, check if checkpointed at correct sequence
    #state{tid = Tid, pids = Pids} = sys:get_state(ServerPid),
    ?assertMatch(#{ChPid := ?DBNAME}, Pids),
    ?assertEqual([{?DBNAME, 11, false, ChPid}], ets:tab2list(Tid)),
    unlink(ServerPid),
    exit(ServerPid, kill).

t_changes_reader_cb_other(_) ->
    ?assertEqual(acc, changes_reader_cb(other, chtype, acc)).

t_handle_call_resume_scan_no_chfeed_no_ets_entry(_) ->
    Tid = mock_ets(),
    State = mock_state(Tid),
    RState = resume_scan(?DBNAME, State),
    % Check if called db_found callback
    ?assert(meck:called(?MOD, db_found, [?DBNAME, zig])),
    % Check if started a change reader
    [{Pid, ?DBNAME}] = maps:to_list(RState#state.pids),
    % Check if inserted checkpoint entry in ets starting at 0
    ?assertEqual([{?DBNAME, 0, false, Pid}], ets:tab2list(Tid)),
    ChArgs = kill_mock_changes_reader_and_get_its_args(Pid),
    ?assertEqual({self(), ?DBNAME}, ChArgs),
    ?assert(
        meck:called(couch_changes, handle_db_changes, [
            #changes_args{
                include_docs = true,
                since = 0,
                feed = "normal",
                timeout = infinity
            },
            {json_req, null},
            db
        ])
    ),
    ets:delete(Tid).

t_handle_call_resume_scan_chfeed_no_ets_entry(_) ->
    Tid = mock_ets(),
    Pid = start_changes_reader(?DBNAME, 0),
    State = mock_state(Tid, Pid),
    resume_scan(?DBNAME, State),
    % Check ets checkpoint is set to 0 and rescan = true
    ?assertEqual([{?DBNAME, 0, true, Pid}], ets:tab2list(Tid)),
    ets:delete(Tid),
    kill_mock_changes_reader_and_get_its_args(Pid).

t_handle_call_resume_scan_chfeed_ets_entry(_) ->
    Tid = mock_ets(),
    Pid = start_changes_reader(?DBNAME, 1),
    State = mock_state(Tid, Pid),
    true = ets:insert(Tid, [{?DBNAME, 2, false, Pid}]),
    resume_scan(?DBNAME, State),
    % Check ets checkpoint is set to same endseq but rescan = true
    ?assertEqual([{?DBNAME, 2, true, Pid}], ets:tab2list(Tid)),
    ets:delete(Tid),
    kill_mock_changes_reader_and_get_its_args(Pid).

t_handle_call_resume_scan_no_chfeed_ets_entry(_) ->
    Tid = mock_ets(),
    true = ets:insert(Tid, [{?DBNAME, 1, true, undefined}]),
    State = mock_state(Tid),
    RState = resume_scan(?DBNAME, State),
    % Check if started a change reader
    [{Pid, ?DBNAME}] = maps:to_list(RState#state.pids),
    % Check if reset rescan to false but kept same endseq
    ?assertEqual([{?DBNAME, 1, false, Pid}], ets:tab2list(Tid)),
    ChArgs = kill_mock_changes_reader_and_get_its_args(Pid),
    ?assertEqual({self(), ?DBNAME}, ChArgs),
    ?assert(
        meck:called(couch_changes, handle_db_changes, [
            #changes_args{
                include_docs = true,
                since = 1,
                feed = "normal",
                timeout = infinity
            },
            {json_req, null},
            db
        ])
    ),
    ets:delete(Tid).

t_start_link(_) ->
    {ok, Pid} = start_link(?SUFFIX, ?MOD, nil, []),
    ?assert(is_pid(Pid)),
    ?assertMatch(
        #state{
            mod = ?MOD,
            suffix = ?SUFFIX,
            ctx = nil,
            pids = #{},
            skip_ddocs = false
        },
        sys:get_state(Pid)
    ),
    unlink(Pid),
    exit(Pid, kill),
    ?assert(meck:called(couch_event, register_all, [Pid])).

t_start_link_no_ddocs(_) ->
    {ok, Pid} = start_link(?SUFFIX, ?MOD, nil, [skip_ddocs]),
    ?assert(is_pid(Pid)),
    ?assertMatch(
        #state{
            mod = ?MOD,
            suffix = ?SUFFIX,
            ctx = nil,
            pids = #{},
            skip_ddocs = true
        },
        sys:get_state(Pid)
    ),
    unlink(Pid),
    exit(Pid, kill).

t_misc_gen_server_callbacks(_) ->
    ?assertEqual(ok, terminate(reason, state)).

scan_dbs_test_() ->
    {
        setup,
        fun() ->
            Ctx = test_util:start_couch([mem3, fabric]),
            GlobalDb = ?tempdb(),
            ok = fabric:create_db(GlobalDb, [?CTX]),
            #shard{name = LocalDb} = hd(mem3:local_shards(GlobalDb)),
            {Ctx, GlobalDb, LocalDb}
        end,
        fun({Ctx, GlobalDb, _LocalDb}) ->
            fabric:delete_db(GlobalDb, [?CTX]),
            test_util:stop_couch(Ctx)
        end,
        with([
            ?TDEF(t_find_shard),
            ?TDEF(t_shard_not_found),
            ?TDEF(t_pass_local),
            ?TDEF(t_fail_local),
            ?TDEF(t_scan_all_dbs)
        ])
    }.

t_find_shard({_, DbName, _}) ->
    ?assertEqual(2, length(local_shards(DbName))).

t_shard_not_found(_) ->
    ?assertEqual([], local_shards(?tempdb())).

t_pass_local({_, _, LocalDb}) ->
    scan_local_db(self(), LocalDb),
    receive
        {'$gen_cast', Msg} ->
            ?assertEqual(Msg, {resume_scan, LocalDb})
    after 0 ->
        ?assert(false)
    end.

t_fail_local({_, _, LocalDb}) ->
    scan_local_db(self(), <<"some_other_db">>),
    receive
        {'$gen_cast', Msg} ->
            ?assertNotEqual(Msg, {resume_scan, LocalDb})
    after 0 ->
        ?assert(true)
    end.

t_scan_all_dbs({_, GlobalDb, _}) ->
    scan_all_dbs(self(), GlobalDb),
    ?assertMatch(
        [
            {'$gen_cast', {resume_scan, <<"shards/00000000-7fffffff/", _/binary>>}},
            {'$gen_cast', {resume_scan, <<"shards/80000000-ffffffff/", _/binary>>}}
        ],
        lists:sort(flush([]))
    ).

flush(Acc) ->
    receive
        Msg ->
            NewMsg = [Msg | Acc],
            case length(NewMsg) >= 2 of
                true -> NewMsg;
                false -> flush(NewMsg)
            end
    after 1000 ->
        Acc
    end.

% Test helper functions

mock_logs() ->
    meck:expect(couch_log, error, 2, ok),
    meck:expect(couch_log, notice, 2, ok),
    meck:expect(couch_log, info, 2, ok),
    meck:expect(couch_log, debug, 2, ok).

mock_callback_mod() ->
    meck:new(?MOD, [non_strict]),
    meck:expect(?MOD, db_created, fun(_DbName, Ctx) -> Ctx end),
    meck:expect(?MOD, db_deleted, fun(_DbName, Ctx) -> Ctx end),
    meck:expect(?MOD, db_found, fun(_DbName, Ctx) -> Ctx end),
    meck:expect(?MOD, db_change, fun(_DbName, _Change, Ctx) -> Ctx end).

mock_changes_reader_loop({_CbFun, {Server, DbName}}) ->
    receive
        die ->
            exit({Server, DbName})
    end.

kill_mock_changes_reader_and_get_its_args(Pid) ->
    Ref = monitor(process, Pid),
    unlink(Pid),
    Pid ! die,
    receive
        {'DOWN', Ref, _, Pid, {Server, DbName}} ->
            {Server, DbName}
    after 1000 ->
        erlang:error(spawn_change_reader_timeout)
    end.

mock_changes_reader() ->
    meck:expect(
        couch_changes,
        handle_db_changes,
        fun
            (_ChArgs, _Req, db) -> fun mock_changes_reader_loop/1;
            (_ChArgs, _Req, dbs) -> fun(_) -> ok end
        end
    ).

mock_ets() ->
    ets:new(multidb_test_ets, [set, public]).

mock_state() ->
    #state{
        mod = ?MOD,
        ctx = zig,
        suffix = ?SUFFIX,
        event_server = esref,
        scanner = spid,
        pids = #{}
    }.

mock_state(Ets) ->
    State = mock_state(),
    State#state{tid = Ets}.

mock_state(Ets, Pid) ->
    State = mock_state(Ets),
    ets:insert(State#state.tid, {?DBNAME, 0, false, Pid}),
    State#state{pids = #{Pid => ?DBNAME}}.

change_row(Id) when is_binary(Id) ->
    {[
        {<<"seq">>, 1},
        {<<"id">>, Id},
        {<<"changes">>, [{[{<<"rev">>, <<"1-f00">>}]}]},
        {doc, {[{<<"_id">>, Id}, {<<"_rev">>, <<"1-f00">>}]}}
    ]}.

handle_call_ok(Msg, State) ->
    handle_call_ok(Msg, from, State).

handle_call_ok(Msg, FromPid, State) ->
    FromTag = make_ref(),
    ?assertMatch({reply, ok, _}, handle_call(Msg, {FromPid, FromTag}, State)).

handle_info_check(Msg, State) ->
    ?assertMatch({noreply, _}, handle_info(Msg, State)).

-endif.
