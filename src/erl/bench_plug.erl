%% Compute-bound benchmark Plug for measuring JIT vs interpreter
%% throughput. Implemented in Erlang (no Elixir 1.18 toolchain on the
%% build host); calls into 'Elixir.Plug.Conn' and 'Elixir.Jason' just
%% like any other Plug-implementing module — Bandit doesn't care what
%% language a Plug is written in.
%%
%% Endpoints:
%%   /hello   — baseline trivial response (network-bound floor)
%%   /json    — Jason encode (binary build + pattern match)
%%   /compute — list fold with integer math (BEAM bytecode)
%%   /fib     — naïve recursive fib(25) (function-call overhead)

-module(bench_plug).
-export([init/1, call/2]).

init(Opts) -> Opts.

call(Conn, _Opts) ->
    Path = maps:get(request_path, Conn),
    case Path of
        <<"/">>        -> handle_root(Conn);
        <<"/health">>  -> respond(Conn, 200, <<"application/json">>,
                                  <<"{\"status\":\"ok\"}">>);
        <<"/hello">>   -> respond(Conn, 200, <<"text/plain">>,
                                  <<"Hello from Phoenix on Tyn!\n">>);
        <<"/json">>    -> handle_json(Conn);
        <<"/compute">> -> handle_compute(Conn);
        <<"/fib">>     -> handle_fib(Conn);
        _              -> respond(Conn, 404, <<"text/plain">>, <<"not found\n">>)
    end.

handle_root(Conn) ->
    Body = <<"Tyn - BEAM on bare metal\n\n"
             "Endpoints:\n"
             "  /          - this page\n"
             "  /health    - health check (200, for load balancers)\n"
             "  /hello     - hello world\n"
             "  /json      - live BEAM stats\n"
             "  /compute   - integer fold benchmark\n"
             "  /fib       - fib(25) benchmark\n">>,
    respond(Conn, 200, <<"text/plain">>, Body).

handle_json(Conn) ->
    Data = #{
        status    => <<"ok">>,
        timestamp => erlang:system_time(millisecond),
        server    => <<"Tyn">>,
        beam      => list_to_binary(erlang:system_info(otp_release)),
        jit       => erlang:system_info(emu_flavor),
        procs     => erlang:system_info(process_count),
        mem       => erlang:memory(total)
    },
    Json = 'Elixir.Jason':'encode!'(Data),
    respond(Conn, 200, <<"application/json">>, Json).

handle_compute(Conn) ->
    Result = lists:foldl(
        fun(I, Acc) -> Acc + ((I * I) rem 997) end,
        0,
        lists:seq(1, 1000)),
    Body = iolist_to_binary(io_lib:format("result: ~p~n", [Result])),
    respond(Conn, 200, <<"text/plain">>, Body).

handle_fib(Conn) ->
    N = 25,
    R = fib(N),
    Body = iolist_to_binary(io_lib:format("fib(~p) = ~p~n", [N, R])),
    respond(Conn, 200, <<"text/plain">>, Body).

fib(0) -> 0;
fib(1) -> 1;
fib(N) -> fib(N - 1) + fib(N - 2).

respond(Conn, Status, ContentType, Body) ->
    Conn2 = 'Elixir.Plug.Conn':put_resp_content_type(Conn, ContentType),
    'Elixir.Plug.Conn':send_resp(Conn2, Status, Body).
