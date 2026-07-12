%% Static-NIF spike loader (CRYPTO_NIF.md Step 1).
%% on_load calls load_nif; if the statically-linked NIF resolves (no dlopen),
%% tyn_nif:add/2 is replaced by the C implementation. If load_nif fails, add/2
%% falls through to the "not loaded" error so the failure is visible.
-module(tyn_nif).
-export([add/2, status/0]).
-on_load(init/0).

init() ->
    %% 0 = load info arg; the second arg to erlang:load_nif is passed to the
    %% NIF's load callback (NULL here).
    case erlang:load_nif("tyn_nif", 0) of
        ok -> ok;
        {error, Reason} ->
            io:format("tyn_nif: load_nif FAILED: ~p~n", [Reason]),
            ok   %% don't block module load; add/2 will report not-loaded
    end.

%% Overridden by the NIF when loaded.
add(_A, _B) -> erlang:nif_error(nif_not_loaded).

status() ->
    try add(1, 2) of
        3 -> io:format("tyn_nif: NIF OK, add(1,2)=3~n");
        Other -> io:format("tyn_nif: unexpected add(1,2)=~p~n", [Other])
    catch
        C:R -> io:format("tyn_nif: NIF NOT loaded (~p:~p)~n", [C, R])
    end.
