-module(cds_keyring_api_tests_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("shamir/include/shamir.hrl").

-export([all/0]).
-export([groups/0]).
-export([init_per_group/2]).
-export([end_per_group/2]).

-export([init/1]).
-export([init_with_timeout/1]).
-export([init_with_cancel/1]).
-export([lock/1]).
-export([unlock/1]).
-export([unlock_with_timeout/1]).
-export([rekey/1]).
-export([rekey_with_timeout/1]).
-export([rekey_with_cancel/1]).
-export([rotate/1]).
-export([rotate_with_timeout/1]).
-export([rotate_with_cancel/1]).
-export([init_invalid_status/1]).
-export([init_invalid_args/1]).
-export([init_operation_aborted_failed_to_recover/1]).
-export([init_operation_aborted_failed_to_decrypt/1]).
-export([init_operation_aborted_non_matching_mk/1]).
-export([lock_invalid_status/1]).
-export([rotate_invalid_status/1]).
-export([rekey_invalid_args/1]).
-export([rekey_invalid_status/1]).
-export([rekey_operation_aborted_failed_to_decrypt_keyring/1]).
-export([rekey_operation_aborted_failed_to_recover_confirm/1]).
-export([rekey_operation_aborted_failed_to_recover_validate/1]).
-export([rekey_operation_aborted_non_matching_masterkey/1]).
-export([rekey_operation_aborted_wrong_masterkey/1]).
-export([rotate_failed_to_recover/1]).
-export([rotate_wrong_masterkey/1]).

-export([decrypt_and_sign_masterkeys/3]).
-export([validate_init/2]).

%%
%% tests descriptions
%%

-type config() :: term().

-spec test() -> _.

-spec all() -> [{group, atom()}].

all() ->
    [
        {group, cds_client_v1},
        {group, cds_client_v2}
    ].

-spec groups() -> [{atom(), list(), [atom()]}].

groups() ->
    [
        {cds_client_v1, [], [{group, all_groups}]},
        {cds_client_v2, [], [{group, all_groups}]},
        {all_groups, [], [
            {group, riak_storage_backend},
            {group, ets_storage_backend},
            {group, keyring_errors}
        ]},
        {riak_storage_backend, [], [{group, basic_lifecycle}]},
        {ets_storage_backend, [], [{group, basic_lifecycle}]},
        {basic_lifecycle, [sequence], [
            init,
            lock,
            unlock,
            rekey,
            rekey_with_timeout,
            rekey_with_cancel,
            rotate_with_timeout,
            lock
        ]},
        {keyring_errors, [sequence], [
            lock_invalid_status,
            init_invalid_args,
            init_with_cancel,
            init_with_timeout,
            init_operation_aborted_failed_to_recover,
            init_operation_aborted_failed_to_decrypt,
            init_operation_aborted_non_matching_mk,
            init,
            init_invalid_status,
            lock,
            lock,
            unlock_with_timeout,
            lock,
            init_invalid_status,
            rotate_invalid_status,
            rekey_invalid_status,
            unlock,
            rekey_invalid_args,
            rekey_operation_aborted_failed_to_decrypt_keyring,
            rekey_operation_aborted_failed_to_recover_confirm,
            rekey_operation_aborted_failed_to_recover_validate,
            rekey_operation_aborted_non_matching_masterkey,
            rekey_operation_aborted_wrong_masterkey,
            rotate_with_cancel,
            rotate_failed_to_recover,
            rotate_wrong_masterkey
        ]}
    ].
%%
%% starting/stopping
%%

-spec init_per_group(atom(), config()) -> config().

init_per_group(cds_client_v1, C) ->
    [
        {cds_keyring_service_code, keyring},
        {cds_storage_client, cds_card_v1_client}
    ] ++ C;

init_per_group(cds_client_v2, C) ->
    [
        {cds_keyring_service_code, keyring_v2},
        {cds_storage_client, cds_card_v2_client}
    ] ++ C;

init_per_group(all_groups, C) ->
    C;

init_per_group(riak_storage_backend, C) ->
    cds_ct_utils:set_riak_storage(C);

init_per_group(ets_storage_backend, C) ->
    cds_ct_utils:set_ets_storage(C);

init_per_group(keyring_errors, C) ->
    StorageConfig = [
        {storage, cds_storage_ets}
    ],
    C1 = cds_ct_utils:start_stash([{storage_config, StorageConfig} | C]),
    cds_ct_utils:start_clear(C1);

init_per_group(_, C) ->
    C1 = cds_ct_utils:start_stash(C),
    cds_ct_utils:start_clear(C1).

-spec end_per_group(atom(), config()) -> _.

end_per_group(Group, C) when
    Group =:= ets_storage_backend;
    Group =:= riak_storage_backend;
    Group =:= all_groups;
    Group =:= cds_client_v1;
    Group =:= cds_client_v2
    ->
    C;

end_per_group(_, C) ->
    cds_ct_utils:stop_clear(C).

%%
%% tests
%%

-spec init(config()) -> _.

init(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    EncryptedMasterKeyShares = cds_keyring_client:start_init(2, root_url(C), CDSKeyringServiceCode),
    Shareholders = cds_shareholder:get_all(),
    _ = ?assertEqual(length(EncryptedMasterKeyShares), length(Shareholders)),
    EncPrivateKeys = enc_private_keys(C),
    SigPrivateKeys = sig_private_keys(C),
    DecryptedMasterKeyShares = decrypt_and_sign_masterkeys(EncryptedMasterKeyShares, EncPrivateKeys, SigPrivateKeys),
    _ = ?assertMatch(
        #{
            status := not_initialized,
            activities := #{
                initialization := #{
                    phase := validation,
                    validation_shares := #{}
                }
            }
        },
        cds_keyring_client:get_state(root_url(C), CDSKeyringServiceCode)
    ),
    ok = validate_init(DecryptedMasterKeyShares, C),
    _ = ?assertMatch(
        #{
            status := unlocked,
            activities := #{
                initialization := #{
                    phase := uninitialized,
                    validation_shares := #{}
                }
            }
        },
        cds_keyring_client:get_state(root_url(C), CDSKeyringServiceCode)
    ),
    cds_ct_utils:store(master_keys, DecryptedMasterKeyShares, C).

-spec init_with_timeout(config()) -> _.

init_with_timeout(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    {Id, DecryptedMasterKeyShare} = partial_init(C),
    Timeout = genlib_app:env(cds, keyring_rotation_lifetime, 4000),
    ok = timer:sleep(Timeout + 1500),
    _ = ?assertEqual(
        {error, {invalid_activity, {initialization, uninitialized}}},
        cds_keyring_client:validate_init(Id, DecryptedMasterKeyShare, root_url(C), CDSKeyringServiceCode)
    ).

-spec init_with_cancel(config()) -> _.

init_with_cancel(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    {Id, DecryptedMasterKeyShare} = partial_init(C),
    ok = cds_keyring_client:cancel_init(root_url(C), CDSKeyringServiceCode),
    _ = ?assertEqual(
        {error, {invalid_activity, {initialization, uninitialized}}},
        cds_keyring_client:validate_init(Id, DecryptedMasterKeyShare, root_url(C), CDSKeyringServiceCode)
    ).

partial_init(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    EncryptedMasterKeyShares = cds_keyring_client:start_init(2, root_url(C), CDSKeyringServiceCode),
    _ = ?assertEqual(
        {error, {invalid_activity, {initialization, validation}}},
        cds_keyring_client:start_init(2, root_url(C), CDSKeyringServiceCode)
    ),
    Shareholders = cds_shareholder:get_all(),
    _ = ?assertEqual(length(EncryptedMasterKeyShares), length(Shareholders)),
    EncPrivateKeys = enc_private_keys(C),
    SigPrivateKeys = sig_private_keys(C),
    [{Id, DecryptedMasterKeyShare} | DecryptedMasterKeyShares] =
        decrypt_and_sign_masterkeys(EncryptedMasterKeyShares, EncPrivateKeys, SigPrivateKeys),
    DecryptedMasterKeySharesCount = length(DecryptedMasterKeyShares),
    _ = ?assertEqual(
        {more_keys_needed, DecryptedMasterKeySharesCount},
        cds_keyring_client:validate_init(Id, DecryptedMasterKeyShare, root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        {more_keys_needed, DecryptedMasterKeySharesCount},
        cds_keyring_client:validate_init(Id, DecryptedMasterKeyShare, root_url(C), CDSKeyringServiceCode)
    ),
    {Id, DecryptedMasterKeyShare}.

-spec decrypt_and_sign_masterkeys(cds_keysharing:encrypted_master_key_shares(), map(), map()) ->
    [{cds_shareholder:shareholder_id(), cds_keysharing:masterkey_share()}].

decrypt_and_sign_masterkeys(EncryptedMasterKeyShares, EncPrivateKeys, SigPrivateKeys) ->
    lists:map(
        fun
            (#{id := Id, owner := Owner, encrypted_share := EncryptedShare}) ->
                {ok, #{id := Id, owner := Owner}} = cds_shareholder:get_by_id(Id),
                EncPrivateKey = maps:get(Id, EncPrivateKeys),
                SigPrivateKey = maps:get(Id, SigPrivateKeys),
                DecryptedShare = cds_crypto:private_decrypt(EncPrivateKey, EncryptedShare),
                {Id, cds_crypto:sign(SigPrivateKey, DecryptedShare)}
        end,
        EncryptedMasterKeyShares).

-spec validate_init([{cds_shareholder:shareholder_id(), cds_keysharing:masterkey_share()}], config()) -> ok.

validate_init([{Id, DecryptedMasterKeyShare} | []], C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    _ = ?assertEqual(
        ok,
        cds_keyring_client:validate_init(Id, DecryptedMasterKeyShare, root_url(C), CDSKeyringServiceCode)
    ),
    ok;
validate_init([{Id, DecryptedMasterKeyShare} | DecryptedMasterKeyShares], C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    DecryptedMasterKeySharesCount = length(DecryptedMasterKeyShares),
    _ = ?assertEqual(
        {more_keys_needed, DecryptedMasterKeySharesCount},
        cds_keyring_client:validate_init(Id, DecryptedMasterKeyShare, root_url(C), CDSKeyringServiceCode)
    ),
    validate_init(DecryptedMasterKeyShares, C).

-spec lock(config()) -> _.

lock(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    ok = cds_keyring_client:lock(root_url(C), CDSKeyringServiceCode).

-spec unlock(config()) -> _.

unlock(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    _ = ?assertMatch(
        #{
            status := locked,
            activities := #{
                unlock := #{
                    phase := uninitialized
                }
            }
        },
        cds_keyring_client:get_state(root_url(C), CDSKeyringServiceCode)
    ),
    [{Id1, MasterKey1}, {Id2, MasterKey2}, _MasterKey3] = cds_ct_utils:lookup(master_keys, C),
    _ = ?assertEqual(ok, cds_keyring_client:start_unlock(root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual({more_keys_needed, 1}, cds_keyring_client:confirm_unlock(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)),
    _ = ?assertMatch(
        #{
            status := locked,
            activities := #{
                unlock := #{
                    phase := validation,
                    confirmation_shares := #{1 := Id1}
                }
            }
        },
        cds_keyring_client:get_state(root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(ok, cds_keyring_client:confirm_unlock(Id2, MasterKey2, root_url(C), CDSKeyringServiceCode)).

-spec unlock_with_timeout(config()) -> _.

unlock_with_timeout(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    [{Id1, MasterKey1}, {Id2, MasterKey2}, _MasterKey3] = cds_ct_utils:lookup(master_keys, C),
    _ = ?assertEqual(ok, cds_keyring_client:start_unlock(root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual(
        {error, {invalid_activity, {unlock, validation}}},
        cds_keyring_client:start_unlock(root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual({more_keys_needed, 1}, cds_keyring_client:confirm_unlock(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual({more_keys_needed, 1}, cds_keyring_client:confirm_unlock(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)),
    Timeout = genlib_app:env(cds, keyring_unlock_lifetime, 1000),
    timer:sleep(Timeout + 500),
    _ = ?assertEqual(ok, cds_keyring_client:start_unlock(root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual({more_keys_needed, 1}, cds_keyring_client:confirm_unlock(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual(ok, cds_keyring_client:confirm_unlock(Id2, MasterKey2, root_url(C), CDSKeyringServiceCode)).

-spec rekey(config()) -> _.

rekey(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    _ = ?assertEqual(ok, cds_keyring_client:start_rekey(2, root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual(
        {error, {invalid_activity, {rekeying, confirmation}}},
        cds_keyring_client:start_rekey(2, root_url(C), CDSKeyringServiceCode)
    ),
    [{Id1, MasterKey1}, {Id2, MasterKey2}, _MasterKey3] = cds_ct_utils:lookup(master_keys, C),
    _ = ?assertEqual(
        {more_keys_needed, 1},
        cds_keyring_client:confirm_rekey(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        {more_keys_needed, 1},
        cds_keyring_client:confirm_rekey(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        ok,
        cds_keyring_client:confirm_rekey(Id2, MasterKey2, root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        {error, {invalid_activity, {rekeying, postconfirmation}}},
        cds_keyring_client:confirm_rekey(Id2, MasterKey2, root_url(C), CDSKeyringServiceCode)
    ),
    EncryptedMasterKeyShares = cds_keyring_client:start_rekey_validation(root_url(C), CDSKeyringServiceCode),
    _ = ?assertMatch(
        #{
            status := unlocked,
            activities := #{
                rekeying := #{
                    phase := validation,
                    confirmation_shares := #{1 := Id1, 2 := Id2},
                    validation_shares := #{}
                }
            }
        },
        cds_keyring_client:get_state(root_url(C), CDSKeyringServiceCode)
    ),
    Shareholders = cds_shareholder:get_all(),
    _ = ?assertEqual(length(EncryptedMasterKeyShares), length(Shareholders)),
    EncPrivateKeys = enc_private_keys(C),
    SigPrivateKeys = sig_private_keys(C),
    DecryptedMasterKeyShares = decrypt_and_sign_masterkeys(EncryptedMasterKeyShares, EncPrivateKeys, SigPrivateKeys),
    ok = validate_rekey(DecryptedMasterKeyShares, C),
    cds_ct_utils:store(master_keys, DecryptedMasterKeyShares, C).

-spec rekey_with_timeout(config()) -> _.

rekey_with_timeout(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    _ = ?assertEqual(ok, cds_keyring_client:start_rekey(2, root_url(C), CDSKeyringServiceCode)),
    [{Id1, MasterKey1}, {Id2, MasterKey2}, _MasterKey3] = cds_ct_utils:lookup(master_keys, C),
    _ = ?assertEqual(
        {more_keys_needed, 1},
        cds_keyring_client:confirm_rekey(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        ok,
        cds_keyring_client:confirm_rekey(Id2, MasterKey2, root_url(C), CDSKeyringServiceCode)
    ),
    Timeout = genlib_app:env(cds, keyring_rekeying_lifetime, 1000),
    timer:sleep(Timeout + 500),
    _ = ?assertEqual(ok, cds_keyring_client:start_rekey(2, root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual(
        {more_keys_needed, 1},
        cds_keyring_client:confirm_rekey(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        ok,
        cds_keyring_client:confirm_rekey(Id2, MasterKey2, root_url(C), CDSKeyringServiceCode)
    ),
    EncryptedMasterKeyShares = cds_keyring_client:start_rekey_validation(root_url(C), CDSKeyringServiceCode),
    Shareholders = cds_shareholder:get_all(),
    _ = ?assertEqual(length(EncryptedMasterKeyShares), length(Shareholders)),
    EncPrivateKeys = enc_private_keys(C),
    SigPrivateKeys = sig_private_keys(C),
    DecryptedMasterKeyShares = decrypt_and_sign_masterkeys(EncryptedMasterKeyShares, EncPrivateKeys, SigPrivateKeys),
    ok = validate_rekey(DecryptedMasterKeyShares, C),
    cds_ct_utils:store(master_keys, DecryptedMasterKeyShares, C).

-spec rekey_with_cancel(config()) -> _.

rekey_with_cancel(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    _ = ?assertEqual(ok, cds_keyring_client:start_rekey(2, root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual(ok, cds_keyring_client:cancel_rekey(root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual(ok, cds_keyring_client:start_rekey(2, root_url(C), CDSKeyringServiceCode)),
    [{Id1, MasterKey1}, {Id2, MasterKey2}, _MasterKey3] = cds_ct_utils:lookup(master_keys, C),
    _ = ?assertEqual(
        {more_keys_needed, 1},
        cds_keyring_client:confirm_rekey(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        ok,
        cds_keyring_client:confirm_rekey(Id2, MasterKey2, root_url(C), CDSKeyringServiceCode)
    ),
    EncryptedMasterKeyShares = cds_keyring_client:start_rekey_validation(root_url(C), CDSKeyringServiceCode),
    Shareholders = cds_shareholder:get_all(),
    _ = ?assertEqual(length(EncryptedMasterKeyShares), length(Shareholders)),
    EncPrivateKeys = enc_private_keys(C),
    SigPrivateKeys = sig_private_keys(C),
    DecryptedMasterKeyShares = decrypt_and_sign_masterkeys(EncryptedMasterKeyShares, EncPrivateKeys, SigPrivateKeys),
    ok = validate_rekey(DecryptedMasterKeyShares, C),
    cds_ct_utils:store(master_keys, DecryptedMasterKeyShares, C).

-spec validate_rekey([{cds_shareholder:shareholder_id(), cds_keysharing:masterkey_share()}], config()) -> ok.

validate_rekey([{Id, DecryptedMasterKeyShare} | []], C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    _ = ?assertEqual(
        ok,
        cds_keyring_client:validate_rekey(Id, DecryptedMasterKeyShare, root_url(C), CDSKeyringServiceCode)
    ),
    ok;
validate_rekey([{Id, DecryptedMasterKeyShare} | DecryptedMasterKeyShares], C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    DecryptedMasterKeySharesCount = length(DecryptedMasterKeyShares),
    _ = ?assertEqual(
        {more_keys_needed, DecryptedMasterKeySharesCount},
        cds_keyring_client:validate_rekey(Id, DecryptedMasterKeyShare, root_url(C), CDSKeyringServiceCode)
    ),
    validate_rekey(DecryptedMasterKeyShares, C).

-spec rotate(config()) -> _.

rotate(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    [{Id1, MasterKey1}, {Id2, MasterKey2}, _MasterKey3] = cds_ct_utils:lookup(master_keys, C),
    _ = ?assertEqual(ok, cds_keyring_client:start_rotate(root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual({more_keys_needed, 1}, cds_keyring_client:confirm_rotate(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual(ok, cds_keyring_client:confirm_rotate(Id2, MasterKey2, root_url(C), CDSKeyringServiceCode)).

-spec rotate_with_timeout(config()) -> _.

rotate_with_timeout(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    [{Id1, MasterKey1}, {Id2, MasterKey2}, {Id3, MasterKey3}] = cds_ct_utils:lookup(master_keys, C),
    _ = ?assertEqual(ok, cds_keyring_client:start_rotate(root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual({more_keys_needed, 1}, cds_keyring_client:confirm_rotate(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)),
    Timeout = genlib_app:env(cds, keyring_rotation_lifetime, 1000),
    timer:sleep(Timeout + 500),
    _ = ?assertEqual(ok, cds_keyring_client:start_rotate(root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual({more_keys_needed, 1}, cds_keyring_client:confirm_rotate(Id2, MasterKey2, root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual(ok, cds_keyring_client:confirm_rotate(Id3, MasterKey3, root_url(C), CDSKeyringServiceCode)).

-spec rotate_with_cancel(config()) -> _.

rotate_with_cancel(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    [{Id1, MasterKey1}, {Id2, MasterKey2}, {Id3, MasterKey3}] = cds_ct_utils:lookup(master_keys, C),
    _ = ?assertEqual(ok, cds_keyring_client:start_rotate(root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual({more_keys_needed, 1}, cds_keyring_client:confirm_rotate(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual(ok, cds_keyring_client:cancel_rotate(root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual(ok, cds_keyring_client:start_rotate(root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual({more_keys_needed, 1}, cds_keyring_client:confirm_rotate(Id2, MasterKey2, root_url(C), CDSKeyringServiceCode)),
    _ = ?assertEqual(ok, cds_keyring_client:confirm_rotate(Id3, MasterKey3, root_url(C), CDSKeyringServiceCode)).

-spec init_invalid_status(config()) -> _.

init_invalid_status(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    _ = ?assertMatch(
        {error, {invalid_status, _SomeStatus}},
        cds_keyring_client:start_init(2, root_url(C), CDSKeyringServiceCode)
    ).

-spec init_invalid_args(config()) -> _.

init_invalid_args(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    _ = ?assertMatch(
        {error, {invalid_arguments, _Reason}},
        cds_keyring_client:start_init(4, root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertMatch(
        {error, {invalid_arguments, _Reason}},
        cds_keyring_client:start_init(0, root_url(C), CDSKeyringServiceCode)
    ).

-spec init_operation_aborted_failed_to_recover(config()) -> _.

init_operation_aborted_failed_to_recover(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    MasterKey = cds_crypto:key(),
    [WrongShare1, WrongShare2, _WrongShare3] = cds_keysharing:share(MasterKey, 2, 3),
    InvalidShare = cds_keysharing:convert(#share{threshold = 2, x = 4, y = <<23224>>}),
    SigPrivateKeys = sig_private_keys(C),
    [{Id1, SigPrivateKey1}, {Id2, SigPrivateKey2}, {Id3, SigPrivateKey3}] =
        maps:to_list(SigPrivateKeys),

    _ = cds_keyring_client:start_init(2, root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 2} = cds_keyring_client:validate_init(Id1, cds_crypto:sign(SigPrivateKey1, WrongShare1), root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:validate_init(Id2, cds_crypto:sign(SigPrivateKey2, WrongShare2), root_url(C), CDSKeyringServiceCode),
    _ = ?assertEqual(
        {error, {operation_aborted, <<"failed_to_recover">>}},
        cds_keyring_client:validate_init(Id3, cds_crypto:sign(SigPrivateKey3, InvalidShare), root_url(C), CDSKeyringServiceCode)
    ).

-spec init_operation_aborted_failed_to_decrypt(config()) -> _.

init_operation_aborted_failed_to_decrypt(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    MasterKey = cds_crypto:key(),
    [WrongShare1, WrongShare2, WrongShare3] = cds_keysharing:share(MasterKey, 2, 3),
    SigPrivateKeys = sig_private_keys(C),
    [{Id1, SigPrivateKey1}, {Id2, SigPrivateKey2}, {Id3, SigPrivateKey3}] =
        maps:to_list(SigPrivateKeys),

    _ = cds_keyring_client:start_init(2, root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 2} = cds_keyring_client:validate_init(Id1, cds_crypto:sign(SigPrivateKey1, WrongShare1), root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:validate_init(Id2, cds_crypto:sign(SigPrivateKey2, WrongShare2), root_url(C), CDSKeyringServiceCode),
    _ = ?assertEqual(
        {error, {operation_aborted, <<"failed_to_decrypt_keyring">>}},
        cds_keyring_client:validate_init(Id3, cds_crypto:sign(SigPrivateKey3, WrongShare3), root_url(C), CDSKeyringServiceCode)
    ).

-spec init_operation_aborted_non_matching_mk(config()) -> _.

init_operation_aborted_non_matching_mk(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    MasterKey = cds_crypto:key(),
    [WrongShare1, WrongShare2, _WrongShare3] = cds_keysharing:share(MasterKey, 1, 3),
    MasterKey2 = cds_crypto:key(),
    [_WrongShare4, _WrongShare5, WrongShare6] = cds_keysharing:share(MasterKey2, 1, 3),
    SigPrivateKeys = sig_private_keys(C),
    [{Id1, SigPrivateKey1}, {Id2, SigPrivateKey2}, {Id3, SigPrivateKey3}] =
        maps:to_list(SigPrivateKeys),

    _ = cds_keyring_client:start_init(1, root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 2} = cds_keyring_client:validate_init(Id1, cds_crypto:sign(SigPrivateKey1, WrongShare1), root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:validate_init(Id2, cds_crypto:sign(SigPrivateKey2, WrongShare2), root_url(C), CDSKeyringServiceCode),
    _ = ?assertEqual(
        {error, {operation_aborted, <<"non_matching_masterkey">>}},
        cds_keyring_client:validate_init(Id3, cds_crypto:sign(SigPrivateKey3, WrongShare6), root_url(C), CDSKeyringServiceCode)
    ).

-spec rekey_operation_aborted_wrong_masterkey(config()) -> _.

rekey_operation_aborted_wrong_masterkey(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    MasterKey = cds_crypto:key(),
    [WrongShare1, WrongShare2, _WrongShare3] = cds_keysharing:share(MasterKey, 2, 3),
    SigPrivateKeys = sig_private_keys(C),
    [{Id1, SigPrivateKey1}, {Id2, SigPrivateKey2}, {_Id3, _SigPrivateKey3}] =
        maps:to_list(SigPrivateKeys),

    ok = cds_keyring_client:start_rekey(2, root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:confirm_rekey(Id1, cds_crypto:sign(SigPrivateKey1, WrongShare1), root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:confirm_rekey(Id1, cds_crypto:sign(SigPrivateKey1, WrongShare1), root_url(C), CDSKeyringServiceCode),
    _ = ?assertEqual(
        {error, {operation_aborted, <<"wrong_masterkey">>}},
        cds_keyring_client:confirm_rekey(Id2, cds_crypto:sign(SigPrivateKey2, WrongShare2), root_url(C), CDSKeyringServiceCode)
    ).

-spec rekey_operation_aborted_failed_to_recover_confirm(config()) -> _.

rekey_operation_aborted_failed_to_recover_confirm(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    MasterKey = cds_crypto:key(),
    [WrongShare1, _WrongShare2, _WrongShare3] = cds_keysharing:share(MasterKey, 2, 3),
    InvalidShare = cds_keysharing:convert(#share{threshold = 2, x = 4, y = <<23224>>}),
    SigPrivateKeys = sig_private_keys(C),
    [{Id1, SigPrivateKey1}, {Id2, SigPrivateKey2}, {_Id3, _SigPrivateKey3}] =
        maps:to_list(SigPrivateKeys),

    ok = cds_keyring_client:start_rekey(2, root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:confirm_rekey(Id1, cds_crypto:sign(SigPrivateKey1, WrongShare1), root_url(C), CDSKeyringServiceCode),
    _ = ?assertEqual(
        {error, {operation_aborted, <<"failed_to_recover">>}},
        cds_keyring_client:confirm_rekey(Id2, cds_crypto:sign(SigPrivateKey2, InvalidShare), root_url(C), CDSKeyringServiceCode)
    ).

-spec rekey_operation_aborted_failed_to_recover_validate(config()) -> _.

rekey_operation_aborted_failed_to_recover_validate(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    [{Id1, TrueSignedShare1}, {Id2, TrueSignedShare2} | _MasterKeys] = cds_ct_utils:lookup(master_keys, C),
    SigPrivateKeys = sig_private_keys(C),
    [{Id1, SigPrivateKey1}, {Id2, SigPrivateKey2}, {Id3, SigPrivateKey3}] =
        maps:to_list(SigPrivateKeys),
    MasterKey = cds_crypto:key(),
    [WrongShare1, WrongShare2, _WrongShare3] = cds_keysharing:share(MasterKey, 2, 3),
    InvalidShare = cds_keysharing:convert(#share{threshold = 2, x = 4, y = <<23224>>}),

    ok = cds_keyring_client:start_rekey(2, root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:confirm_rekey(Id1, TrueSignedShare1, root_url(C), CDSKeyringServiceCode),
    ok = cds_keyring_client:confirm_rekey(Id2, TrueSignedShare2, root_url(C), CDSKeyringServiceCode),
    _ = cds_keyring_client:start_rekey_validation(root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 2} = cds_keyring_client:validate_rekey(Id1, cds_crypto:sign(SigPrivateKey1, WrongShare1), root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:validate_rekey(Id2, cds_crypto:sign(SigPrivateKey2, WrongShare2), root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:validate_rekey(Id2, cds_crypto:sign(SigPrivateKey2, WrongShare2), root_url(C), CDSKeyringServiceCode),
    _ = ?assertEqual(
        {error, {operation_aborted, <<"failed_to_recover">>}},
        cds_keyring_client:validate_rekey(Id3, cds_crypto:sign(SigPrivateKey3, InvalidShare), root_url(C), CDSKeyringServiceCode)
    ).

-spec rekey_operation_aborted_failed_to_decrypt_keyring(config()) -> _.

rekey_operation_aborted_failed_to_decrypt_keyring(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    [{Id1, TrueSignedShare1}, {Id2, TrueSignedShare2} | _MasterKeys] = cds_ct_utils:lookup(master_keys, C),
    SigPrivateKeys = sig_private_keys(C),
    [{Id1, SigPrivateKey1}, {Id2, SigPrivateKey2}, {Id3, SigPrivateKey3}] =
        maps:to_list(SigPrivateKeys),
    MasterKey = cds_crypto:key(),
    [WrongShare1, WrongShare2, WrongShare3] = cds_keysharing:share(MasterKey, 2, 3),

    ok = cds_keyring_client:start_rekey(2, root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:confirm_rekey(Id1, TrueSignedShare1, root_url(C), CDSKeyringServiceCode),
    ok = cds_keyring_client:confirm_rekey(Id2, TrueSignedShare2, root_url(C), CDSKeyringServiceCode),
    _ = cds_keyring_client:start_rekey_validation(root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 2} = cds_keyring_client:validate_rekey(Id1, cds_crypto:sign(SigPrivateKey1, WrongShare1), root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:validate_rekey(Id2, cds_crypto:sign(SigPrivateKey2, WrongShare2), root_url(C), CDSKeyringServiceCode),
    _ = ?assertEqual(
        {error, {operation_aborted, <<"failed_to_decrypt_keyring">>}},
        cds_keyring_client:validate_rekey(Id3, cds_crypto:sign(SigPrivateKey3, WrongShare3), root_url(C), CDSKeyringServiceCode)
    ).


-spec rekey_operation_aborted_non_matching_masterkey(config()) -> _.

rekey_operation_aborted_non_matching_masterkey(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    [{Id1, TrueSignedShare1}, {Id2, TrueSignedShare2} | _MasterKeys] = cds_ct_utils:lookup(master_keys, C),
    SigPrivateKeys = sig_private_keys(C),
    [{Id1, SigPrivateKey1}, {Id2, SigPrivateKey2}, {Id3, SigPrivateKey3}] =
        maps:to_list(SigPrivateKeys),
    MasterKey = cds_crypto:key(),
    [WrongShare1, WrongShare2, _WrongShare3] = cds_keysharing:share(MasterKey, 1, 3),
    MasterKey2 = cds_crypto:key(),
    [_WrongShare4, _WrongShare5, WrongShare6] = cds_keysharing:share(MasterKey2, 1, 3),

    ok = cds_keyring_client:start_rekey(1, root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:confirm_rekey(Id1, TrueSignedShare1, root_url(C), CDSKeyringServiceCode),
    ok = cds_keyring_client:confirm_rekey(Id2, TrueSignedShare2, root_url(C), CDSKeyringServiceCode),
    _ = cds_keyring_client:start_rekey_validation(root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 2} = cds_keyring_client:validate_rekey(Id1, cds_crypto:sign(SigPrivateKey1, WrongShare1), root_url(C), CDSKeyringServiceCode),
    {more_keys_needed, 1} = cds_keyring_client:validate_rekey(Id2, cds_crypto:sign(SigPrivateKey2, WrongShare2), root_url(C), CDSKeyringServiceCode),
    _ = ?assertEqual(
        {error, {operation_aborted, <<"non_matching_masterkey">>}},
        cds_keyring_client:validate_rekey(Id3, cds_crypto:sign(SigPrivateKey3, WrongShare6), root_url(C), CDSKeyringServiceCode)
    ).

-spec rekey_invalid_args(config()) -> _.

rekey_invalid_args(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    _ = ?assertMatch(
        {error, {invalid_arguments, _Reason}},
        cds_keyring_client:start_rekey(4, root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertMatch(
        {error, {invalid_arguments, _Reason}},
        cds_keyring_client:start_rekey(0, root_url(C), CDSKeyringServiceCode)
    ).

-spec rekey_invalid_status(config()) -> _.

rekey_invalid_status(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    _ = ?assertMatch(
        {error, {invalid_status, _SomeStatus}},
        cds_keyring_client:start_rekey(2, root_url(C), CDSKeyringServiceCode)
    ).

-spec lock_invalid_status(config()) -> _.

lock_invalid_status(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    _ = ?assertMatch(
        {error, {invalid_status, _SomeStatus}},
        cds_keyring_client:lock(root_url(C), CDSKeyringServiceCode)
    ).

-spec rotate_invalid_status(config()) -> _.

rotate_invalid_status(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    _ = ?assertMatch(
        {error, {invalid_status, _SomeStatus}},
        cds_keyring_client:start_rotate(root_url(C), CDSKeyringServiceCode)
    ).

-spec rotate_failed_to_recover(config()) -> _.

rotate_failed_to_recover(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    [{Id1, MasterKey1}, {Id2, _MasterKey2} | _MasterKeys] = cds_ct_utils:lookup(master_keys, C),
    MasterKey2 = cds_keysharing:convert(#share{threshold = 2, x = 4, y = <<23224>>}),
    SigPrivateKeys = sig_private_keys(C),
    [_SigPrivateKey1, SigPrivateKey2, _SigPrivateKey3] = maps:values(SigPrivateKeys),
    _ = ?assertEqual(
        ok,
        cds_keyring_client:start_rotate(root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        {error, {invalid_activity, {rotation, validation}}},
        cds_keyring_client:start_rotate(root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        {more_keys_needed, 1},
        cds_keyring_client:confirm_rotate(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        {more_keys_needed, 1},
        cds_keyring_client:confirm_rotate(Id1, MasterKey1, root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        {error, {operation_aborted, <<"failed_to_recover">>}},
        cds_keyring_client:confirm_rotate(Id2, cds_crypto:sign(SigPrivateKey2, MasterKey2), root_url(C), CDSKeyringServiceCode)
    ).

-spec rotate_wrong_masterkey(config()) -> _.

rotate_wrong_masterkey(C) ->
    CDSKeyringServiceCode = config(cds_keyring_service_code, C),
    MasterKey = cds_crypto:key(),
    [MasterKey1, MasterKey2, _MasterKey3] = cds_keysharing:share(MasterKey, 2, 3),
    SigPrivateKeys = sig_private_keys(C),
    [{Id1, SigPrivateKey1}, {Id2, SigPrivateKey2}, _SigPrivateKey3] = maps:to_list(SigPrivateKeys),
    _ = ?assertEqual(
        ok,
        cds_keyring_client:start_rotate(root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        {more_keys_needed, 1},
        cds_keyring_client:confirm_rotate(Id1, cds_crypto:sign(SigPrivateKey1, MasterKey1), root_url(C), CDSKeyringServiceCode)
    ),
    _ = ?assertEqual(
        {error, {operation_aborted, <<"wrong_masterkey">>}},
        cds_keyring_client:confirm_rotate(Id2, cds_crypto:sign(SigPrivateKey2, MasterKey2), root_url(C), CDSKeyringServiceCode)
    ).

%%
%% helpers
%%


config(Key, Config) ->
    config(Key, Config, undefined).

config(Key, Config, Default) ->
    case lists:keysearch(Key, 1, Config) of
        {value, {Key, Val}} ->
            Val;
        _ ->
            Default
    end.

root_url(C) ->
    config(root_url, C).

enc_private_keys(C) ->
    config(enc_private_keys, C).

sig_private_keys(C) ->
    config(sig_private_keys, C).