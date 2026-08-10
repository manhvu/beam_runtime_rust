%% XMM-preemption detector — Erlang loader for the static NIF built into beam.smp
%% (beam-build/nifs/xmm_probe.c, linked via --enable-static-nifs). See
%% directions/XMM_DETECTOR.md and tests/simd/README.md.
%%
%% probe(Outer, Spin) keeps a known value live in xmm0/xmm1 across `Outer`
%% call-free spins (each `Spin` GP-counter iterations, long enough to be
%% timer-preempted) and returns how many spans came back corrupted. Non-zero =>
%% a preemption clobbered XMM and it was not restored. This is a true
%% XMM-register detector, unlike the amplifier's md5/bincopy (which catch memory
%% corruption).
-module(xmm_probe).
-export([probe/2, available/0]).
-on_load(init/0).

init() ->
    case erlang:load_nif("xmm_probe", 0) of
        ok -> ok;
        {error, Reason} ->
            io:format("xmm_probe: load_nif FAILED: ~p~n", [Reason]),
            ok
    end.

probe(_Outer, _Spin) -> erlang:nif_error(nif_not_loaded).

available() ->
    try probe(1, 1) of
        N when is_integer(N) -> true
    catch
        _:_ -> false
    end.
