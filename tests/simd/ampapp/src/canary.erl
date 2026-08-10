%% Memory-read canary — Erlang loader for the static NIF (beam-build/nifs/canary.c).
%% read(Outer) -> {Bad, LastOff, LastStale, LastExp, BufAddr, StaleCtxHex}.
%% See directions/TLB_CANARY.md and tests/simd/README.md.
-module(canary).
-export([read/1, available/0]).
-on_load(init/0).

init() ->
    case erlang:load_nif("canary", 0) of
        ok -> ok;
        {error, Reason} ->
            io:format("canary: load_nif FAILED: ~p~n", [Reason]),
            ok
    end.

read(_Outer) -> erlang:nif_error(nif_not_loaded).

available() ->
    try read(1) of
        {B, _, _, _, _, _} when is_integer(B) -> true;
        _ -> false
    catch
        _:_ -> false
    end.
