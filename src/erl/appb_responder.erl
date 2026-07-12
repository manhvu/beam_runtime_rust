%% App B for Track 1 Phase 1c — a deliberately different app.
%%
%% This is NOT Phoenix and NOT a Bandit Plug: a plain gen_tcp HTTP/1.1 responder
%% in pure Erlang, depending only on kernel/stdlib. That lets App B ship in a
%% minimal cpio (all Elixir.* beams removed), so its cpio is a very different
%% size from App A's full-Phoenix image — which is exactly what exercises 1b's
%% size-parameterised staging-zero at a different `mod_end`.
%%
%% tyn_boot starts it generically via boot.config's
%%   {start_mfa, {appb_responder, start, [8080]}}.
%%
%% Request parsing is raw (split the first line on spaces) rather than
%% {packet,http} so it leans on nothing beyond gen_tcp recv/send. One acceptor
%% process, one handler per connection, Connection: close — enough to serve
%% `curl /hello`, which is all Phase 1c asks of it.

-module(appb_responder).
-export([start/1]).

start(Port) ->
    {ok, L} = gen_tcp:listen(Port, [binary,
                                    {active, false},
                                    {packet, raw},
                                    {reuseaddr, true},
                                    {backlog, 16}]),
    spawn(fun() -> accept_loop(L) end),
    ok.

accept_loop(L) ->
    case gen_tcp:accept(L) of
        {ok, S} ->
            spawn(fun() -> handle(S) end),
            accept_loop(L);
        {error, _} ->
            %% Listener gone — stop the loop rather than spin.
            ok
    end.

handle(S) ->
    case gen_tcp:recv(S, 0) of
        {ok, Data} -> respond(S, route(Data));
        {error, _} -> ok
    end,
    gen_tcp:close(S).

%% "GET /hello HTTP/1.1\r\n..." -> the second space-delimited field is the path.
route(Data) ->
    case binary:split(Data, <<" ">>, [global]) of
        [_Method, Path | _] -> path_body(Path);
        _                   -> {400, <<"bad request\n">>}
    end.

path_body(<<"/hello">>) -> {200, <<"Hello from App B on Tyn!\n">>};
path_body(<<"/">>)      -> {200, <<"App B (plain gen_tcp) on Tyn\n">>};
path_body(_)            -> {404, <<"not found\n">>}.

respond(S, {Code, Body}) ->
    Reason = case Code of
                 200 -> "OK";
                 404 -> "Not Found";
                 _   -> "Bad Request"
             end,
    Resp = [io_lib:format("HTTP/1.1 ~p ~s\r\n", [Code, Reason]),
            "Content-Type: text/plain\r\n",
            io_lib:format("Content-Length: ~p\r\n", [byte_size(Body)]),
            "Connection: close\r\n\r\n",
            Body],
    gen_tcp:send(S, Resp).
