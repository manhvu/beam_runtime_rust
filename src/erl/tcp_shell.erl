%% Minimal TCP eval shell for Tyn.
%%
%% Listens on a port, accepts connections, reads lines and evaluates
%% them with erl_eval. Bindings are per-session. Multi-line
%% expressions are buffered until erl_parse accepts the input.
%%
%% Each connection is served by its own process. The accept loop
%% re-spawns itself so multiple clients can connect concurrently
%% (within whatever the kernel listener pool supports).

-module(tcp_shell).
-export([start/1, accept_loop/1, session/1]).

start(Port) ->
    Opts = [binary, {active, false}, {reuseaddr, true}, {packet, line}],
    case gen_tcp:listen(Port, Opts) of
        {ok, LSock} ->
            spawn(?MODULE, accept_loop, [LSock]),
            {ok, LSock};
        {error, Reason} = Err ->
            io:format("tcp_shell listen ~p failed: ~p~n", [Port, Reason]),
            Err
    end.

accept_loop(LSock) ->
    case gen_tcp:accept(LSock) of
        {ok, Sock} ->
            %% Standard ownership-handoff pattern:
            %%   1. spawn the session process; it blocks waiting
            %%      for our "go" message before touching the socket.
            %%   2. transfer controlling_process to it.
            %%   3. send "go" so it knows ownership is settled.
            %% Without the handoff the socket's owner is the
            %% accept_loop pid; when accept_loop's first accept call
            %% returns the next time, ERTS would treat the previous
            %% socket as orphaned and close it.
            SessionPid = spawn(?MODULE, session, [Sock]),
            ok = gen_tcp:controlling_process(Sock, SessionPid),
            SessionPid ! {go, self()},
            accept_loop(LSock);
        {error, _} ->
            ok
    end.

session(Sock) ->
    %% Wait for the accept_loop to finish the ownership handoff.
    receive {go, _} -> ok end,
    Banner = io_lib:format(
        "Tyn eval shell - OTP ~s, ERTS ~s~n"
        "Expressions end in '.'   Disconnect to exit.~n"
        ">> ",
        [erlang:system_info(otp_release), erlang:system_info(version)]),
    gen_tcp:send(Sock, iolist_to_binary(Banner)),
    loop(Sock, [], erl_eval:new_bindings()).

%% Acc is the accumulated source for a multi-line expression.
%% When erl_parse accepts the accumulated text, evaluate.
loop(Sock, Acc, Bindings) ->
    case gen_tcp:recv(Sock, 0) of
        {ok, Line} ->
            Chunk = unicode:characters_to_list(Line),
            Trimmed = string:trim(Chunk, trailing),
            case Acc ++ Trimmed of
                "" ->
                    gen_tcp:send(Sock, <<">> ">>),
                    loop(Sock, [], Bindings);
                Src ->
                    case try_parse(Src) of
                        {complete, Exprs} ->
                            NewBindings = eval_and_reply(Sock, Exprs, Bindings),
                            loop(Sock, [], NewBindings);
                        incomplete ->
                            %% Need more input — continuation prompt.
                            gen_tcp:send(Sock, <<".. ">>),
                            loop(Sock, Src ++ " ", Bindings);
                        {error, Reason} ->
                            gen_tcp:send(Sock,
                                iolist_to_binary(io_lib:format(
                                    "** parse error: ~p~n>> ", [Reason]))),
                            loop(Sock, [], Bindings)
                    end
            end;
        {error, closed} -> ok;
        {error, _}      -> ok
    end.

%% Returns {complete, Exprs} | incomplete | {error, Reason}.
try_parse(Src) ->
    Terminator = case lists:reverse(Src) of
        [$. | _] -> "";   %% already terminated
        _        -> "."
    end,
    case erl_scan:string(Src ++ Terminator) of
        {ok, Tokens, _} ->
            case erl_parse:parse_exprs(Tokens) of
                {ok, Exprs}                    -> {complete, Exprs};
                {error, {_, _, ["syntax error before: ", _]}} ->
                    %% Could be incomplete; let the caller try more input.
                    incomplete;
                {error, R} -> {error, R}
            end;
        {error, _, _} -> incomplete
    end.

eval_and_reply(Sock, Exprs, Bindings) ->
    try
        {value, Value, NewBindings} = erl_eval:exprs(Exprs, Bindings),
        Reply = io_lib:format("~p~n>> ", [Value]),
        gen_tcp:send(Sock, iolist_to_binary(Reply)),
        NewBindings
    catch
        Class:Reason:Stack ->
            Err = io_lib:format(
                "** ~p:~p~n   stack: ~p~n>> ",
                [Class, Reason, lists:sublist(Stack, 5)]),
            gen_tcp:send(Sock, iolist_to_binary(Err)),
            Bindings
    end.
