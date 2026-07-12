%% Rust static-NIF spike loader (CRYPTO_NIF.md Step 1, Rust variant).
%% Mirrors tyn_nif.erl but loads the pure-Rust staticlib NIF.
-module(tyn_rust_nif).
-export([add/2, status/0]).
-on_load(init/0).

init() ->
    case erlang:load_nif("tyn_rust_nif", 0) of
        ok -> ok;
        {error, Reason} ->
            io:format("tyn_rust_nif: load_nif FAILED: ~p~n", [Reason]),
            ok
    end.

add(_A, _B) -> erlang:nif_error(nif_not_loaded).

status() ->
    try add(2, 3) of
        5 -> io:format("tyn_rust_nif: NIF OK, add(2,3)=5~n");
        Other -> io:format("tyn_rust_nif: unexpected add(2,3)=~p~n", [Other])
    catch
        C:R -> io:format("tyn_rust_nif: NIF NOT loaded (~p:~p)~n", [C, R])
    end.
