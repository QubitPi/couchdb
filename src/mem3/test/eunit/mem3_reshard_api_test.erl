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

-module(mem3_reshard_api_test).

-include_lib("couch/include/couch_eunit.hrl").
-include_lib("couch/include/couch_db.hrl").
-include_lib("mem3/src/mem3_reshard.hrl").

-define(USER, "mem3_reshard_api_test_admin").
-define(PASS, "pass").
-define(AUTH, {basic_auth, {?USER, ?PASS}}).
-define(JSON, {"Content-Type", "application/json"}).
-define(RESHARD, "_reshard/").
-define(JOBS, "_reshard/jobs/").
-define(STATE, "_reshard/state").
-define(ID, <<"id">>).
-define(OK, <<"ok">>).
% seconds
-define(TIMEOUT, 60).

setup() ->
    Hashed = couch_passwords:hash_admin_password(?PASS),
    ok = config:set("admins", ?USER, ?b2l(Hashed), _Persist = false),
    Addr = config:get("chttpd", "bind_address", "127.0.0.1"),
    Port = mochiweb_socket_server:get(chttpd, port),
    Url = lists:concat(["http://", Addr, ":", Port, "/"]),
    {Db1, Db2, Db3} = {?tempdb(), ?tempdb(), ?tempdb()},
    create_db(Url, Db1, "?q=1&n=1"),
    create_db(Url, Db2, "?q=1&n=1"),
    create_db(Url, Db3, "?q=2&n=1"),
    {Url, {Db1, Db2, Db3}}.

teardown({Url, {Db1, Db2, Db3}}) ->
    mem3_reshard:reset_state(),
    application:unset_env(mem3, reshard_disabled),
    delete_db(Url, Db1),
    delete_db(Url, Db2),
    delete_db(Url, Db3),
    Persist = false,
    ok = config:delete("reshard", "max_jobs", Persist),
    ok = config:delete("reshard", "require_node_param", Persist),
    ok = config:delete("reshard", "require_range_param", Persist),
    ok = config:delete("reshard", "max_retries", Persist),
    ok = config:delete("reshard", "retry_interval_sec", Persist),
    ok = config:delete("admins", ?USER, Persist),
    meck:unload().

start_couch() ->
    test_util:start_couch([mem3, chttpd]).

stop_couch(Ctx) ->
    test_util:stop_couch(Ctx).

mem3_reshard_api_test_() ->
    {
        "mem3 shard split api tests",
        {
            setup,
            fun start_couch/0,
            fun stop_couch/1,
            {
                foreach,
                fun setup/0,
                fun teardown/1,
                [
                    fun basics/1,
                    fun create_job_basic/1,
                    fun create_two_jobs/1,
                    fun create_multiple_jobs_from_one_post/1,
                    fun start_stop_cluster_basic/1,
                    fun test_disabled/1,
                    fun start_stop_cluster_with_a_job/1,
                    fun individual_job_start_stop/1,
                    fun individual_job_start_after_failure/1,
                    fun individual_job_stop_when_cluster_stopped/1,
                    fun create_job_with_invalid_arguments/1,
                    fun create_job_with_db/1,
                    fun create_job_with_shard_name/1,
                    fun completed_job_handling/1,
                    fun handle_db_deletion_in_initial_copy/1,
                    fun handle_db_deletion_in_topoff1/1,
                    fun handle_db_deletion_in_copy_local_docs/1,
                    fun handle_db_deletion_in_build_indices/1,
                    fun handle_db_deletion_in_update_shard_map/1,
                    fun handle_db_deletion_in_wait_source_close/1,
                    fun recover_in_initial_copy/1,
                    fun recover_in_topoff1/1,
                    fun recover_in_copy_local_docs/1,
                    fun recover_in_build_indices/1,
                    fun recover_in_update_shard_map/1,
                    fun recover_in_wait_source_close/1,
                    fun recover_in_topoff3/1,
                    fun recover_in_source_delete/1,
                    fun check_max_jobs/1,
                    fun check_node_and_range_required_params/1,
                    fun cleanup_completed_jobs/1
                ]
            }
        }
    }.

basics({Top, _}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            % GET /_reshard
            ?assertMatch(
                {200, #{
                    <<"state">> := <<"running">>,
                    <<"state_reason">> := null,
                    <<"completed">> := 0,
                    <<"failed">> := 0,
                    <<"running">> := 0,
                    <<"stopped">> := 0,
                    <<"total">> := 0
                }},
                req(get, Top ++ ?RESHARD)
            ),

            % GET _reshard/state
            ?assertMatch(
                {200, #{<<"state">> := <<"running">>}},
                req(get, Top ++ ?STATE)
            ),

            % GET _reshard/jobs
            ?assertMatch(
                {200, #{
                    <<"jobs">> := [],
                    <<"offset">> := 0,
                    <<"total_rows">> := 0
                }},
                req(get, Top ++ ?JOBS)
            ),

            % Some invalid paths and methods
            ?assertMatch({404, _}, req(get, Top ++ ?RESHARD ++ "/invalidpath")),
            ?assertMatch({405, _}, req(put, Top ++ ?RESHARD, #{dont => thinkso})),
            ?assertMatch({405, _}, req(post, Top ++ ?RESHARD, #{nope => nope}))
        end)}.

create_job_basic({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            % POST /_reshard/jobs
            {C1, R1} = req(post, Top ++ ?JOBS, #{type => split, db => Db1}),
            ?assertEqual(201, C1),
            ?assertMatch(
                [#{?OK := true, ?ID := J, <<"shard">> := S}] when
                    is_binary(J) andalso is_binary(S),
                R1
            ),
            [#{?ID := Id, <<"shard">> := Shard}] = R1,

            % GET /_reshard/jobs
            ?assertMatch(
                {200, #{
                    <<"jobs">> := [#{?ID := Id, <<"type">> := <<"split">>}],
                    <<"offset">> := 0,
                    <<"total_rows">> := 1
                }},
                req(get, Top ++ ?JOBS)
            ),

            % GET /_reshard/job/$jobid
            {C2, R2} = req(get, Top ++ ?JOBS ++ ?b2l(Id)),
            ?assertEqual(200, C2),
            ThisNode = atom_to_binary(node(), utf8),
            ?assertMatch(#{?ID := Id}, R2),
            ?assertMatch(#{<<"type">> := <<"split">>}, R2),
            ?assertMatch(#{<<"source">> := Shard}, R2),
            ?assertMatch(#{<<"history">> := History} when length(History) > 1, R2),
            ?assertMatch(#{<<"node">> := ThisNode}, R2),
            ?assertMatch(#{<<"split_state">> := SSt} when is_binary(SSt), R2),
            ?assertMatch(#{<<"job_state">> := JSt} when is_binary(JSt), R2),
            ?assertMatch(#{<<"state_info">> := #{}}, R2),
            ?assertMatch(#{<<"target">> := Target} when length(Target) == 2, R2),

            % GET  /_reshard/job/$jobid/state
            ?assertMatch(
                {200, #{<<"state">> := S, <<"reason">> := R}} when
                    is_binary(S) andalso (is_binary(R) orelse R =:= null),
                req(get, Top ++ ?JOBS ++ ?b2l(Id) ++ "/state")
            ),

            % GET /_reshard
            ?assertMatch(
                {200, #{<<"state">> := <<"running">>, <<"total">> := 1}},
                req(get, Top ++ ?RESHARD)
            ),

            % DELETE /_reshard/jobs/$jobid
            ?assertMatch(
                {200, #{?OK := true}},
                req(delete, Top ++ ?JOBS ++ ?b2l(Id))
            ),

            % GET _reshard/jobs
            ?assertMatch(
                {200, #{<<"jobs">> := [], <<"total_rows">> := 0}},
                req(get, Top ++ ?JOBS)
            ),

            % GET /_reshard/job/$jobid should be a 404
            ?assertMatch({404, #{}}, req(get, Top ++ ?JOBS ++ ?b2l(Id))),

            % DELETE /_reshard/jobs/$jobid  should be a 404 as well
            ?assertMatch({404, #{}}, req(delete, Top ++ ?JOBS ++ ?b2l(Id)))
        end)}.

create_two_jobs({Top, {Db1, Db2, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            Jobs = Top ++ ?JOBS,

            ?assertMatch(
                {201, [#{?OK := true}]},
                req(post, Jobs, #{type => split, db => Db1})
            ),
            ?assertMatch(
                {201, [#{?OK := true}]},
                req(post, Jobs, #{type => split, db => Db2})
            ),

            ?assertMatch({200, #{<<"total">> := 2}}, req(get, Top ++ ?RESHARD)),

            ?assertMatch(
                {200, #{
                    <<"jobs">> := [#{?ID := Id1}, #{?ID := Id2}],
                    <<"offset">> := 0,
                    <<"total_rows">> := 2
                }} when Id1 =/= Id2,
                req(get, Jobs)
            ),

            {200, #{<<"jobs">> := [#{?ID := Id1}, #{?ID := Id2}]}} = req(get, Jobs),

            {200, #{?OK := true}} = req(delete, Jobs ++ ?b2l(Id1)),
            ?assertMatch({200, #{<<"total">> := 1}}, req(get, Top ++ ?RESHARD)),
            {200, #{?OK := true}} = req(delete, Jobs ++ ?b2l(Id2)),
            ?assertMatch({200, #{<<"total">> := 0}}, req(get, Top ++ ?RESHARD))
        end)}.

create_multiple_jobs_from_one_post({Top, {_, _, Db3}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            Jobs = Top ++ ?JOBS,
            {C1, R1} = req(post, Jobs, #{type => split, db => Db3}),
            ?assertMatch({201, [#{?OK := true}, #{?OK := true}]}, {C1, R1}),
            ?assertMatch({200, #{<<"total">> := 2}}, req(get, Top ++ ?RESHARD))
        end)}.

start_stop_cluster_basic({Top, _}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            Url = Top ++ ?STATE,

            ?assertMatch(
                {200, #{
                    <<"state">> := <<"running">>,
                    <<"reason">> := null
                }},
                req(get, Url)
            ),

            ?assertMatch({200, _}, req(put, Url, #{state => stopped})),
            ?assertMatch(
                {200, #{
                    <<"state">> := <<"stopped">>,
                    <<"reason">> := R
                }} when is_binary(R),
                req(get, Url)
            ),

            ?assertMatch({200, _}, req(put, Url, #{state => running})),

            % Make sure the reason shows in the state GET request
            Reason = <<"somereason">>,
            ?assertMatch(
                {200, _},
                req(put, Url, #{
                    state => stopped,
                    reason => Reason
                })
            ),
            ?assertMatch(
                {200, #{
                    <<"state">> := <<"stopped">>,
                    <<"reason">> := Reason
                }},
                req(get, Url)
            ),

            % Top level summary also shows the reason
            ?assertMatch(
                {200, #{
                    <<"state">> := <<"stopped">>,
                    <<"state_reason">> := Reason
                }},
                req(get, Top ++ ?RESHARD)
            ),
            ?assertMatch({200, _}, req(put, Url, #{state => running})),
            ?assertMatch({200, #{<<"state">> := <<"running">>}}, req(get, Url))
        end)}.

test_disabled({Top, _}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            application:set_env(mem3, reshard_disabled, true),
            ?assertMatch({501, _}, req(get, Top ++ ?RESHARD)),
            ?assertMatch({501, _}, req(put, Top ++ ?STATE, #{state => running})),

            application:unset_env(mem3, reshard_disabled),
            ?assertMatch({200, _}, req(get, Top ++ ?RESHARD)),
            ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => running}))
        end)}.

start_stop_cluster_with_a_job({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            Url = Top ++ ?STATE,

            ?assertMatch({200, _}, req(put, Url, #{state => stopped})),
            ?assertMatch({200, #{<<"state">> := <<"stopped">>}}, req(get, Url)),

            % Can add jobs with global state stopped, they just won't be running
            {201, R1} = req(post, Top ++ ?JOBS, #{type => split, db => Db1}),
            ?assertMatch([#{?OK := true}], R1),
            [#{?ID := Id1}] = R1,
            {200, J1} = req(get, Top ++ ?JOBS ++ ?b2l(Id1)),
            ?assertMatch(#{?ID := Id1, <<"job_state">> := <<"stopped">>}, J1),
            % Check summary stats
            ?assertMatch(
                {200, #{
                    <<"state">> := <<"stopped">>,
                    <<"running">> := 0,
                    <<"stopped">> := 1,
                    <<"total">> := 1
                }},
                req(get, Top ++ ?RESHARD)
            ),

            % Can delete the job when stopped
            {200, #{?OK := true}} = req(delete, Top ++ ?JOBS ++ ?b2l(Id1)),
            ?assertMatch(
                {200, #{
                    <<"state">> := <<"stopped">>,
                    <<"running">> := 0,
                    <<"stopped">> := 0,
                    <<"total">> := 0
                }},
                req(get, Top ++ ?RESHARD)
            ),

            % Add same job again
            {201, [#{?ID := Id2}]} = req(post, Top ++ ?JOBS, #{
                type => split,
                db => Db1
            }),
            ?assertMatch(
                {200, #{?ID := Id2, <<"job_state">> := <<"stopped">>}},
                req(get, Top ++ ?JOBS ++ ?b2l(Id2))
            ),

            % Job should start after resharding is started on the cluster
            ?assertMatch({200, _}, req(put, Url, #{state => running})),
            ?assertMatch(
                {200, #{?ID := Id2, <<"job_state">> := JSt}} when
                    JSt =/= <<"stopped">>,
                req(get, Top ++ ?JOBS ++ ?b2l(Id2))
            )
        end)}.

individual_job_start_stop({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            intercept_state(topoff1),

            Body = #{type => split, db => Db1},
            {201, [#{?ID := Id}]} = req(post, Top ++ ?JOBS, Body),

            JobUrl = Top ++ ?JOBS ++ ?b2l(Id),
            StUrl = JobUrl ++ "/state",

            % Wait for the the job to start running and intercept it in topoff1 state
            receive
                {JobPid, topoff1} -> ok
            end,
            % Tell the intercept to never finish checkpointing so job is left hanging
            % forever in running state
            JobPid ! cancel,
            ?assertMatch({200, #{<<"state">> := <<"running">>}}, req(get, StUrl)),

            {200, _} = req(put, StUrl, #{state => stopped}),
            wait_state(StUrl, <<"stopped">>),

            % Stop/start resharding globally and job should still stay stopped
            ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => stopped})),
            ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => running})),
            ?assertMatch({200, #{<<"state">> := <<"stopped">>}}, req(get, StUrl)),

            % Start the job again
            ?assertMatch({200, _}, req(put, StUrl, #{state => running})),
            % Wait for the the job to start running and intercept it in topoff1 state
            receive
                {JobPid2, topoff1} -> ok
            end,
            ?assertMatch({200, #{<<"state">> := <<"running">>}}, req(get, StUrl)),
            % Let it continue running and it should complete eventually
            JobPid2 ! continue,
            wait_state(StUrl, <<"completed">>)
        end)}.

individual_job_start_after_failure({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            config:set("reshard", "retry_interval_sec", "0", false),
            config:set("reshard", "max_retries", "1", false),
            meck:expect(couch_db_split, split, fun(_, _, _) ->
                meck:exception(error, kapow)
            end),

            Body = #{type => split, db => Db1},
            {201, [#{?ID := Id}]} = req(post, Top ++ ?JOBS, Body),

            JobUrl = Top ++ ?JOBS ++ ?b2l(Id),
            StUrl = JobUrl ++ "/state",

            wait_state(StUrl, <<"failed">>),

            % Stop/start resharding globally and job should still stay failed
            ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => stopped})),
            ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => running})),
            ?assertMatch({200, #{<<"state">> := <<"failed">>}}, req(get, StUrl)),

            meck:unload(),

            % Start the job again
            ?assertMatch({200, _}, req(put, StUrl, #{state => running})),
            wait_state(StUrl, <<"completed">>)
        end)}.

individual_job_stop_when_cluster_stopped({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            intercept_state(topoff1),

            Body = #{type => split, db => Db1},
            {201, [#{?ID := Id}]} = req(post, Top ++ ?JOBS, Body),

            JobUrl = Top ++ ?JOBS ++ ?b2l(Id),
            StUrl = JobUrl ++ "/state",

            % Wait for the the job to start running and intercept in topoff1
            receive
                {JobPid, topoff1} -> ok
            end,
            % Tell the intercept to never finish checkpointing so job is left
            % hanging forever in running state
            JobPid ! cancel,
            ?assertMatch({200, #{<<"state">> := <<"running">>}}, req(get, StUrl)),

            % Stop resharding globally
            ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => stopped})),
            wait_state(StUrl, <<"stopped">>),

            % Stop the job specifically
            {200, _} = req(put, StUrl, #{state => stopped}),
            % Job stays stopped
            ?assertMatch({200, #{<<"state">> := <<"stopped">>}}, req(get, StUrl)),

            % Set cluster to running again
            ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => running})),

            % The job should stay stopped
            ?assertMatch({200, #{<<"state">> := <<"stopped">>}}, req(get, StUrl)),

            % It should be possible to resume job and it should complete
            ?assertMatch({200, _}, req(put, StUrl, #{state => running})),

            % Wait for the the job to start running and intercept in topoff1 state
            receive
                {JobPid2, topoff1} -> ok
            end,
            ?assertMatch({200, #{<<"state">> := <<"running">>}}, req(get, StUrl)),

            % Let it continue running and it should complete eventually
            JobPid2 ! continue,
            wait_state(StUrl, <<"completed">>)
        end)}.

create_job_with_invalid_arguments({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            Jobs = Top ++ ?JOBS,

            % Nothing in the body
            ?assertMatch({400, _}, req(post, Jobs, #{})),

            % Missing type
            ?assertMatch({400, _}, req(post, Jobs, #{db => Db1})),

            % Have type but no db and no shard
            ?assertMatch({400, _}, req(post, Jobs, #{type => split})),

            % Have type and db but db is invalid
            ?assertMatch(
                {400, _},
                req(post, Jobs, #{
                    db => <<"baddb">>,
                    type => split
                })
            ),

            % Have type and shard but shard is not an existing database
            ?assertMatch(
                {404, _},
                req(post, Jobs, #{
                    type => split,
                    shard => <<"shards/80000000-ffffffff/baddb.1549492084">>
                })
            ),

            % Bad range values, too large, different types, inverted
            ?assertMatch(
                {400, _},
                req(post, Jobs, #{
                    db => Db1,
                    range => 42,
                    type => split
                })
            ),
            ?assertMatch(
                {400, _},
                req(post, Jobs, #{
                    db => Db1,
                    range => <<"x">>,
                    type => split
                })
            ),
            ?assertMatch(
                {400, _},
                req(post, Jobs, #{
                    db => Db1,
                    range => <<"ffffffff-80000000">>,
                    type => split
                })
            ),
            ?assertMatch(
                {400, _},
                req(post, Jobs, #{
                    db => Db1,
                    range => <<"00000000-fffffffff">>,
                    type => split
                })
            ),

            % Can't have both db and shard
            ?assertMatch(
                {400, _},
                req(post, Jobs, #{
                    type => split,
                    db => Db1,
                    shard => <<"blah">>
                })
            )
        end)}.

create_job_with_db({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            Jobs = Top ++ ?JOBS,
            Body1 = #{type => split, db => Db1},

            % Node with db
            N = atom_to_binary(node(), utf8),
            {C1, R1} = req(post, Jobs, Body1#{node => N}),
            ?assertMatch({201, [#{?OK := true}]}, {C1, R1}),
            wait_to_complete_then_cleanup(Top, R1),

            % Range and db
            {C2, R2} = req(post, Jobs, Body1#{range => <<"00000000-7fffffff">>}),
            ?assertMatch({201, [#{?OK := true}]}, {C2, R2}),
            wait_to_complete_then_cleanup(Top, R2),

            % Node, range and db
            Range = <<"80000000-ffffffff">>,
            {C3, R3} = req(post, Jobs, Body1#{range => Range, node => N}),
            ?assertMatch({201, [#{?OK := true}]}, {C3, R3}),
            wait_to_complete_then_cleanup(Top, R3),

            ?assertMatch(
                [
                    [16#00000000, 16#3fffffff],
                    [16#40000000, 16#7fffffff],
                    [16#80000000, 16#bfffffff],
                    [16#c0000000, 16#ffffffff]
                ],
                [mem3:range(S) || S <- lists:sort(mem3:shards(Db1))]
            )
        end)}.

create_job_with_shard_name({Top, {_, _, Db3}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            Jobs = Top ++ ?JOBS,
            [S1, S2] = [mem3:name(S) || S <- lists:sort(mem3:shards(Db3))],

            % Shard only
            {C1, R1} = req(post, Jobs, #{type => split, shard => S1}),
            ?assertMatch({201, [#{?OK := true}]}, {C1, R1}),
            wait_to_complete_then_cleanup(Top, R1),

            % Shard with a node
            N = atom_to_binary(node(), utf8),
            {C2, R2} = req(post, Jobs, #{type => split, shard => S2, node => N}),
            ?assertMatch({201, [#{?OK := true}]}, {C2, R2}),
            wait_to_complete_then_cleanup(Top, R2),

            ?assertMatch(
                [
                    [16#00000000, 16#3fffffff],
                    [16#40000000, 16#7fffffff],
                    [16#80000000, 16#bfffffff],
                    [16#c0000000, 16#ffffffff]
                ],
                [mem3:range(S) || S <- lists:sort(mem3:shards(Db3))]
            )
        end)}.

completed_job_handling({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            Jobs = Top ++ ?JOBS,

            % Run job to completion
            {C1, R1} = req(post, Jobs, #{type => split, db => Db1}),
            ?assertMatch({201, [#{?OK := true}]}, {C1, R1}),
            [#{?ID := Id}] = R1,
            wait_to_complete(Top, R1),

            % Check top level stats
            ?assertMatch(
                {200, #{
                    <<"state">> := <<"running">>,
                    <<"state_reason">> := null,
                    <<"completed">> := 1,
                    <<"failed">> := 0,
                    <<"running">> := 0,
                    <<"stopped">> := 0,
                    <<"total">> := 1
                }},
                req(get, Top ++ ?RESHARD)
            ),

            % Job state itself
            JobUrl = Jobs ++ ?b2l(Id),
            ?assertMatch(
                {200, #{
                    <<"split_state">> := <<"completed">>,
                    <<"job_state">> := <<"completed">>
                }},
                req(get, JobUrl)
            ),

            % Job's state endpoint
            StUrl = Jobs ++ ?b2l(Id) ++ "/state",
            ?assertMatch({200, #{<<"state">> := <<"completed">>}}, req(get, StUrl)),

            % Try to stop it and it should stay completed
            {200, _} = req(put, StUrl, #{state => stopped}),
            ?assertMatch({200, #{<<"state">> := <<"completed">>}}, req(get, StUrl)),

            % Try to resume it and it should stay completed
            {200, _} = req(put, StUrl, #{state => running}),
            ?assertMatch({200, #{<<"state">> := <<"completed">>}}, req(get, StUrl)),

            % Stop resharding globally and job should still stay completed
            ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => stopped})),
            ?assertMatch({200, #{<<"state">> := <<"completed">>}}, req(get, StUrl)),

            % Start resharding and job stays completed
            ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => running})),
            ?assertMatch({200, #{<<"state">> := <<"completed">>}}, req(get, StUrl)),

            ?assertMatch({200, #{?OK := true}}, req(delete, JobUrl))
        end)}.

handle_db_deletion_in_topoff1({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = delete_source_in_state(Top, Db1, topoff1),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"failed">>)
        end)}.

handle_db_deletion_in_initial_copy({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = delete_source_in_state(Top, Db1, initial_copy),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"failed">>)
        end)}.

handle_db_deletion_in_copy_local_docs({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = delete_source_in_state(Top, Db1, copy_local_docs),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"failed">>)
        end)}.

handle_db_deletion_in_build_indices({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = delete_source_in_state(Top, Db1, build_indices),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"failed">>)
        end)}.

handle_db_deletion_in_update_shard_map({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = delete_source_in_state(Top, Db1, update_shardmap),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"failed">>)
        end)}.

handle_db_deletion_in_wait_source_close({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = delete_source_in_state(Top, Db1, wait_source_close),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"failed">>)
        end)}.

recover_in_topoff1({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = recover_in_state(Top, Db1, topoff1),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"completed">>)
        end)}.

recover_in_initial_copy({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = recover_in_state(Top, Db1, initial_copy),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"completed">>)
        end)}.

recover_in_copy_local_docs({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = recover_in_state(Top, Db1, copy_local_docs),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"completed">>)
        end)}.

recover_in_build_indices({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = recover_in_state(Top, Db1, build_indices),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"completed">>)
        end)}.

recover_in_update_shard_map({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = recover_in_state(Top, Db1, update_shardmap),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"completed">>)
        end)}.

recover_in_wait_source_close({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = recover_in_state(Top, Db1, wait_source_close),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"completed">>)
        end)}.

recover_in_topoff3({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = recover_in_state(Top, Db1, topoff3),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"completed">>)
        end)}.

recover_in_source_delete({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            JobId = recover_in_state(Top, Db1, source_delete),
            wait_state(Top ++ ?JOBS ++ ?b2l(JobId) ++ "/state", <<"completed">>)
        end)}.

check_max_jobs({Top, {Db1, Db2, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            Jobs = Top ++ ?JOBS,
            Persist = false,

            config:set("reshard", "max_jobs", "0", Persist),
            {C1, R1} = req(post, Jobs, #{type => split, db => Db1}),
            ?assertMatch({500, [#{<<"error">> := <<"max_jobs_exceeded">>}]}, {C1, R1}),

            config:set("reshard", "max_jobs", "1", Persist),
            {201, R2} = req(post, Jobs, #{type => split, db => Db1}),
            wait_to_complete(Top, R2),

            % Stop clustering so jobs are not started anymore and ensure max jobs
            % is enforced even if jobs are stopped
            ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => stopped})),

            {C3, R3} = req(post, Jobs, #{type => split, db => Db2}),
            ?assertMatch(
                {500, [#{<<"error">> := <<"max_jobs_exceeded">>}]},
                {C3, R3}
            ),

            % Allow the job to be created by raising max_jobs
            config:set("reshard", "max_jobs", "2", Persist),

            {C4, R4} = req(post, Jobs, #{type => split, db => Db2}),
            ?assertEqual(201, C4),

            % Lower max_jobs after job is created but it's not running
            config:set("reshard", "max_jobs", "1", Persist),

            % Start resharding again
            ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => running})),

            % Jobs that have been created already are not removed if max jobs is lowered
            % so make sure the job completes
            wait_to_complete(Top, R4)
        end)}.

check_node_and_range_required_params({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            Jobs = Top ++ ?JOBS,
            Persist = false,

            Node = atom_to_binary(node(), utf8),
            Range = <<"00000000-ffffffff">>,

            config:set("reshard", "require_node_param", "true", Persist),
            {C1, R1} = req(post, Jobs, #{type => split, db => Db1}),
            NodeRequiredErr = <<"`node` prameter is required">>,
            ?assertEqual(
                {400, #{
                    <<"error">> => <<"bad_request">>,
                    <<"reason">> => NodeRequiredErr
                }},
                {C1, R1}
            ),

            config:set("reshard", "require_range_param", "true", Persist),
            {C2, R2} = req(post, Jobs, #{type => split, db => Db1, node => Node}),
            RangeRequiredErr = <<"`range` prameter is required">>,
            ?assertEqual(
                {400, #{
                    <<"error">> => <<"bad_request">>,
                    <<"reason">> => RangeRequiredErr
                }},
                {C2, R2}
            ),

            Body = #{type => split, db => Db1, range => Range, node => Node},
            {C3, R3} = req(post, Jobs, Body),
            ?assertMatch({201, [#{?OK := true}]}, {C3, R3}),
            wait_to_complete_then_cleanup(Top, R3)
        end)}.

cleanup_completed_jobs({Top, {Db1, _, _}}) ->
    {timeout, ?TIMEOUT,
        ?_test(begin
            Body = #{type => split, db => Db1},
            {201, [#{?ID := Id}]} = req(post, Top ++ ?JOBS, Body),
            JobUrl = Top ++ ?JOBS ++ ?b2l(Id),
            wait_state(JobUrl ++ "/state", <<"completed">>),
            delete_db(Top, Db1),
            wait_for_http_code(JobUrl, 404)
        end)}.

% Test help functions

wait_to_complete_then_cleanup(Top, Jobs) ->
    JobsUrl = Top ++ ?JOBS,
    lists:foreach(
        fun(#{?ID := Id}) ->
            wait_state(JobsUrl ++ ?b2l(Id) ++ "/state", <<"completed">>),
            {200, _} = req(delete, JobsUrl ++ ?b2l(Id))
        end,
        Jobs
    ).

wait_to_complete(Top, Jobs) ->
    JobsUrl = Top ++ ?JOBS,
    lists:foreach(
        fun(#{?ID := Id}) ->
            wait_state(JobsUrl ++ ?b2l(Id) ++ "/state", <<"completed">>)
        end,
        Jobs
    ).

intercept_state(State) ->
    TestPid = self(),
    meck:new(mem3_reshard_job, [passthrough]),
    meck:expect(mem3_reshard_job, checkpoint_done, fun(Job) ->
        case Job#job.split_state of
            State ->
                TestPid ! {self(), State},
                receive
                    continue -> meck:passthrough([Job]);
                    cancel -> ok
                end;
            _ ->
                meck:passthrough([Job])
        end
    end).

cancel_intercept() ->
    meck:expect(mem3_reshard_job, checkpoint_done, fun(Job) ->
        meck:passthrough([Job])
    end).

wait_state(Url, State) ->
    test_util:wait(
        fun() ->
            case req(get, Url) of
                {200, #{<<"state">> := State}} ->
                    ok;
                {200, #{}} ->
                    timer:sleep(100),
                    wait
            end
        end,
        30000
    ).

wait_for_http_code(Url, Code) when is_integer(Code) ->
    test_util:wait(
        fun() ->
            case req(get, Url) of
                {Code, _} ->
                    ok;
                {_, _} ->
                    timer:sleep(100),
                    wait
            end
        end,
        30000
    ).

delete_source_in_state(Top, Db, State) when is_atom(State), is_binary(Db) ->
    intercept_state(State),
    Body = #{type => split, db => Db},
    {201, [#{?ID := Id}]} = req(post, Top ++ ?JOBS, Body),
    receive
        {JobPid, State} -> ok
    end,
    sync_delete_db(Top, Db),
    JobPid ! continue,
    Id.

recover_in_state(Top, Db, State) when is_atom(State) ->
    intercept_state(State),
    Body = #{type => split, db => Db},
    {201, [#{?ID := Id}]} = req(post, Top ++ ?JOBS, Body),
    receive
        {JobPid, State} -> ok
    end,
    % Job is now stuck in running we prevented it from executing
    % the given state
    JobPid ! cancel,
    % Now restart resharding
    ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => stopped})),
    cancel_intercept(),
    ?assertMatch({200, _}, req(put, Top ++ ?STATE, #{state => running})),
    Id.

create_db(Top, Db, QArgs) when is_binary(Db) ->
    Url = Top ++ binary_to_list(Db) ++ QArgs,
    {ok, Status, _, _} = test_request:put(Url, [?JSON, ?AUTH], "{}"),
    ?assert(Status =:= 201 orelse Status =:= 202).

delete_db(Top, Db) when is_binary(Db) ->
    Url = Top ++ binary_to_list(Db),
    case test_request:get(Url, [?AUTH]) of
        {ok, 404, _, _} ->
            not_found;
        {ok, 200, _, _} ->
            {ok, 200, _, _} = test_request:delete(Url, [?AUTH]),
            ok
    end.

sync_delete_db(Top, Db) when is_binary(Db) ->
    delete_db(Top, Db),
    try
        Shards = mem3:local_shards(Db),
        ShardNames = [mem3:name(S) || S <- Shards],
        [couch_server:delete(N, [?ADMIN_CTX]) || N <- ShardNames],
        ok
    catch
        error:database_does_not_exist ->
            ok
    end.

req(Method, Url) ->
    Headers = [?AUTH],
    {ok, Code, _, Res} = test_request:request(Method, Url, Headers),
    {Code, jiffy:decode(Res, [return_maps])}.

req(Method, Url, #{} = Body) ->
    req(Method, Url, jiffy:encode(Body));
req(Method, Url, Body) ->
    Headers = [?JSON, ?AUTH],
    {ok, Code, _, Res} = test_request:request(Method, Url, Headers, Body),
    {Code, jiffy:decode(Res, [return_maps])}.
