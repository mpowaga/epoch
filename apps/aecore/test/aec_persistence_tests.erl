-module(aec_persistence_tests).

-include_lib("eunit/include/eunit.hrl").
-include("common.hrl").
-include("blocks.hrl").

-define(compareBlockResults(B1, B2),
        ?assertEqual(aec_blocks:serialize_to_map(B1),
                     aec_blocks:serialize_to_map(B2))).

block_hash(B) ->
    {ok, Hash} = aec_headers:hash_header(aec_blocks:to_header(B)),
    Hash.

header_hash(Header) ->
    {ok, Hash} = aec_headers:hash_header(Header),
    Hash.

ts() -> integer_to_list(erlang:system_time()).

init_persistence() ->
    put('__persist__', application:get_env(aecore, persist, false)),
    application:set_env(aecore, persist, true),
    Path = ".test_" ++ ts(),
    file:make_dir(Path),
    {ok, _} = aec_persistence:start_link(Path),
    Path.

cleanup_persistence(Path) ->
    Persist = get('__persist__'),
    application:set_env(aecore, persist, Persist),
    ok = aec_persistence:stop_and_clean(),
    file:del_dir(Path),
    ok.

kill_and_restart_conductor() ->
    %% Stop server
    ok = aec_conductor:stop(),
    %% check that it is dead.
    dead =
        try aec_conductor:top()
        catch exit:{noproc, _} -> dead
        end,
    %% Restart server
    {ok, _} = aec_conductor:start_link([{autostart, false}]),
    server_up = wait_for_conductor(),
    ok.

wait_for_conductor() ->
    try aec_conductor:top(),
        server_up
    catch exit:{noproc, _} -> 
        timer:sleep(10),
        wait_for_conductor()
    end.

write_test_() ->
    {foreach,
     fun() ->
             init_persistence()
     end,
     fun(Path) ->
             cleanup_persistence(Path)
     end,
     [{"Write a block to storage and read it back.",
       fun() ->
               GB = aec_test_utils:genesis_block(),
               ok = aec_persistence:write_block(GB),
               ok = aec_persistence:sync(),
               Hash = block_hash(GB),

               Block = aec_persistence:get_block(Hash),

               %% Check block apart from state trees.
               ?compareBlockResults(GB, Block),
               ok
       end}]}.

write_chain_test_() ->
    {foreach,
     fun() ->
             aec_test_utils:start_chain_db(),
             meck:new(aec_pow_cuckoo, [passthrough]),
             meck:expect(aec_pow_cuckoo, verify, fun(_, _, _, _) -> true end),
             meck:new(aec_events, [passthrough]),
             meck:expect(aec_events, publish, fun(_, _) -> ok end),
             aec_test_utils:mock_genesis(),
             TmpDir = aec_test_utils:aec_keys_setup(),
             Path = init_persistence(),
             {ok, _} = aec_tx_pool:start_link(),
             {ok, _} = aec_conductor:start_link([{autostart, false}]),
             {Path, TmpDir}
     end,
     fun({Path, TmpDir}) ->
             ok = aec_conductor:stop(),
             ok = aec_tx_pool:stop(),
             meck:unload(aec_pow_cuckoo),
             meck:unload(aec_events),
             aec_test_utils:unmock_genesis(),
             cleanup_persistence(Path),
             aec_test_utils:stop_chain_db(),
             aec_test_utils:aec_keys_cleanup(TmpDir)
     end,
     [{"Write a block to chain and read it back.",
       fun() ->
               GB = aec_test_utils:genesis_block(),
               ok = aec_conductor:post_block(GB),

               Hash = block_hash(GB),

               Block = aec_db:get_block(Hash),

               %% Check block apart from state trees.
               ?compareBlockResults(GB, Block),

               %% Genesis should be top header
               Header = aec_db:get_top_header(),
               ?assertEqual(Header, Hash),

               %% Genesis should be top block
               TopBlockHash = aec_db:get_top_block(),
               ?assertEqual(Header, TopBlockHash),

               ok
       end},
      {"Build chain with genesis block plus 2 headers, then store block corresponding to top header",
       fun() ->
               [GB, B1, B2] = aec_test_utils:gen_blocks_only_chain(3),
               %% Add a couple of headers - not blocks - to the chain.
               BH1 = aec_blocks:to_header(B1),
               ?assertEqual(ok, aec_conductor:post_header(BH1)),
               BH2 = aec_blocks:to_header(B2),
               ?assertEqual(ok, aec_conductor:post_header(BH2)),

               GHash = block_hash(GB),

               Block = aec_db:get_block(GHash),

               %% Check block apart from state trees.
               ?compareBlockResults(GB, Block),

               %% BH2 should be top header
               Header = aec_db:get_top_header(),
               B2Hash = header_hash(BH2),
               ?assertEqual(B2Hash, Header),

               %% Genesis should be top block
               TopBlockHash = aec_db:get_top_block(),
               ?assertEqual(GHash, TopBlockHash),

               %% Add one block corresponding to a header already in the chain.
               ?assertEqual(ok, aec_conductor:post_block(B2)),

               %% GB should still be top block
               NewTopBlockHash = aec_db:get_top_block(),
               ?assertEqual(GHash, NewTopBlockHash),

               %% Add missing block corresponding to a header already in the chain.
               ?assertEqual(ok, aec_conductor:post_block(B1)),

               %% Now B2 should be the top block
               LastTopBlockHash = aec_db:get_top_block(),
               ?assertEqual(B2Hash, LastTopBlockHash),

               ok
       end}
     ]}.


restart_test_() ->
    {foreach,
     fun() ->
             TmpDir = aec_test_utils:aec_keys_setup(),
             aec_test_utils:start_chain_db(),
             Path = init_persistence(),
             meck:new(aec_events, [passthrough]),
             meck:expect(aec_events, publish, fun(_, _) -> ok end),
             meck:new(aec_pow_cuckoo, [passthrough]),
             meck:expect(aec_pow_cuckoo, verify, fun(_, _, _, _) -> true end),
             aec_test_utils:mock_genesis(),
             {ok, _} = aec_tx_pool:start_link(),
             {ok, _} = aec_conductor:start_link([{autostart, false}]),
             {Path, TmpDir}
     end,
     fun({Path, TmpDir}) ->
             ok = aec_tx_pool:stop(),
             meck:unload(aec_pow_cuckoo),
             meck:unload(aec_events),
             aec_test_utils:unmock_genesis(),
             aec_test_utils:stop_chain_db(),
             cleanup_persistence(Path),
             aec_test_utils:aec_keys_cleanup(TmpDir)
     end,
     [{"Build chain, then kill server, check that chain is read back.",
       fun() ->
               [GB, B1, B2] = aec_test_utils:gen_blocks_only_chain(3),
               BH2 = aec_blocks:to_header(B2),
               ?assertEqual({ok, GB}, aec_conductor:get_block_by_height(0)),
               ?assertEqual(ok, aec_conductor:post_block(B1)),
               ?assertEqual(ok, aec_conductor:post_block(B2)),
               aec_persistence:sync(),
               %% Now B2 should be the top block
               TopBlockHash = aec_db:get_top_block(),
               B2Hash = header_hash(BH2),
               ?assertEqual(B2Hash, TopBlockHash),
               ChainTop1 = aec_conductor:top(),
               ?assertEqual(ChainTop1, aec_conductor:top()),
               ?compareBlockResults(B2, ChainTop1),

               %% Check the state trees from persistence
               {ok, ChainTop1Hash} =
                   aec_blocks:hash_internal_representation(ChainTop1),
               {ok, ChainTop1State} =
                   aec_conductor:get_block_state_by_hash(ChainTop1Hash),
               ?assertEqual(ChainTop1State,
                            aec_db:get_block_state(TopBlockHash)),

               %% Kill chain server

               kill_and_restart_conductor(),
               %% aec_persistence:sync(),
               NewTopBlockHash = aec_db:get_top_block(),
               ?assertEqual(B2Hash, NewTopBlockHash),

               ChainTop2 = aec_conductor:top(),
               ?assertEqual(ChainTop2, aec_conductor:top()),
               ?compareBlockResults(B2, ChainTop2),

               %% Compare the trees after restart
               %% Check the state trees from persistence
               {ok, ChainTop2Hash} =
                   aec_blocks:hash_internal_representation(ChainTop2),
               {ok, ChainTop2State} =
                   aec_conductor:get_block_state_by_hash(ChainTop2Hash),
               ?assertEqual(ChainTop1State,
                            ChainTop2State),

               ok
       end}
     ]}.
