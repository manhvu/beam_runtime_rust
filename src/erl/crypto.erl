%% Tyn's replacement `crypto` module (Option A). Replaces OTP's crypto.beam in
%% the cpio. on_load resolves the static Rust crypto NIF (crypto_nif_init); the
%% NIF replaces the stubs below. Implements exactly the surface Phoenix/Plug use
%% (Step 3). Capability probes are pure Erlang so libraries that call
%% crypto:supports/0,1 or info_lib/0 don't crash on missing exports.
%%
%% NOTE: Tyn's crypto is new and unreviewed; do not trust it for production
%% session security until it has had outside review.
-module(crypto).

-export([strong_rand_bytes/1, hash/2, mac/4, pbkdf2_hmac/5, exor/2, hash_equals/2,
         crypto_one_time_aead/6, crypto_one_time_aead/7,
         supports/0, supports/1, info_lib/0, version/0]).

-on_load(on_load/0).

on_load() ->
    erlang:load_nif("crypto", 0).

%% --- NIF-backed (stubs replaced on successful load) ---
strong_rand_bytes(_N) -> erlang:nif_error(nif_not_loaded).
hash(_Type, _Data) -> erlang:nif_error(nif_not_loaded).
mac(_Type, _SubType, _Key, _Data) -> erlang:nif_error(nif_not_loaded).
pbkdf2_hmac(_Digest, _Pass, _Salt, _Iter, _Len) -> erlang:nif_error(nif_not_loaded).
exor(_A, _B) -> erlang:nif_error(nif_not_loaded).
hash_equals(_A, _B) -> erlang:nif_error(nif_not_loaded).
crypto_one_time_aead(_C, _K, _IV, _In, _AAD, _TagOrFlag) -> erlang:nif_error(nif_not_loaded).
crypto_one_time_aead(_C, _K, _IV, _In, _AAD, _Tag, _Flag) -> erlang:nif_error(nif_not_loaded).

%% --- pure-Erlang capability probes ---
supports() ->
    [{hashs, [sha, sha224, sha256, sha384, sha512]},
     {ciphers, [aes_128_gcm, aes_256_gcm, chacha20_poly1305]},
     {macs, [hmac]},
     {public_keys, []},
     {curves, []},
     {rsa_opts, []}].

supports(hashs)       -> [sha, sha224, sha256, sha384, sha512];
supports(macs)        -> [hmac];
supports(ciphers)     -> [aes_128_gcm, aes_256_gcm, chacha20_poly1305];
supports(public_keys) -> [];
supports(curves)      -> [];
supports(_)           -> [].

info_lib() -> [{<<"Tyn RustCrypto">>, 1, <<"tyn-crypto-nif 0.1 (unreviewed)">>}].

version() -> "tyn-crypto-nif-0.1".
