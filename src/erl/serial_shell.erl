%% Serial eval shell for Tyn — same eval loop as tcp_shell, but over the
%% COM1 serial port (fd 0 / fd 1) instead of a TCP socket. This is what an
%% operator reaches through the AWS EC2 Serial Console (IAM-authenticated,
%% no open ports).
%%
%% open_port({fd,0,1}, ...) reads stdin / writes stdout directly, bypassing
%% OTP's user_drv/TTY machinery (which needs a real terminal). The kernel
%% echoes typed characters and turns DEL/BS into an on-screen erase + a DEL
%% byte; this module strips that DEL from its line buffer. Newlines arrive as
%% '\n'; output is emitted as "\r\n" for raw serial terminals.

-module(serial_shell).
-export([start/0]).

start() ->
    spawn(fun() ->
        Port = open_port({fd, 0, 1}, [stream, binary]),
        out(Port, banner()),
        loop(Port, [], [], erl_eval:new_bindings())
    end).

banner() ->
    io_lib:format(
        "Tyn serial shell - OTP ~s, ERTS ~s\r\n"
        "Expressions end in '.'\r\n>> ",
        [erlang:system_info(otp_release), erlang:system_info(version)]).

%% Line = current physical line, reverse char list (for O(1) push/backspace)
%% Src  = accumulated source across continuation lines
loop(Port, Line, Src, Bindings) ->
    receive
        {Port, {data, Data}} ->
            {NewLine, NewSrc, NewB} = feed(Port, binary_to_list(Data), Line, Src, Bindings),
            loop(Port, NewLine, NewSrc, NewB);
        {Port, closed} -> ok;
        _Other -> loop(Port, Line, Src, Bindings)
    end.

feed(_Port, [], Line, Src, B) ->
    {Line, Src, B};
feed(Port, [$\n | Rest], Line, Src, B) ->
    {NewSrc, NewB} = handle_line(Port, lists:reverse(Line), Src, B),
    feed(Port, Rest, [], NewSrc, NewB);
feed(Port, [C | Rest], Line, Src, B) when C =:= 127; C =:= 8 ->
    NewLine = case Line of [] -> []; [_ | T] -> T end,
    feed(Port, Rest, NewLine, Src, B);
feed(Port, [C | Rest], Line, Src, B) ->
    feed(Port, Rest, [C | Line], Src, B).

handle_line(Port, LineStr, Src, B) ->
    Trimmed = string:trim(LineStr, trailing),
    case Src ++ Trimmed of
        "" ->
            out(Port, ">> "),
            {[], B};
        Combined ->
            case try_parse(Combined) of
                {complete, Exprs} ->
                    NewB = eval_reply(Port, Exprs, B),
                    {[], NewB};
                incomplete ->
                    out(Port, ".. "),
                    {Combined ++ " ", B};
                {error, R} ->
                    out(Port, io_lib:format("** parse error: ~p\r\n>> ", [R])),
                    {[], B}
            end
    end.

%% Returns {complete, Exprs} | incomplete | {error, Reason}.
try_parse(Src) ->
    Terminator = case lists:reverse(Src) of
        [$. | _] -> "";
        _        -> "."
    end,
    case erl_scan:string(Src ++ Terminator) of
        {ok, Tokens, _} ->
            case erl_parse:parse_exprs(Tokens) of
                {ok, Exprs} -> {complete, Exprs};
                {error, {_, _, ["syntax error before: ", _]}} -> incomplete;
                {error, R} -> {error, R}
            end;
        {error, _, _} -> incomplete
    end.

eval_reply(Port, Exprs, Bindings) ->
    try
        {value, Value, NewBindings} = erl_eval:exprs(Exprs, Bindings),
        out(Port, io_lib:format("~p\r\n>> ", [Value])),
        NewBindings
    catch
        Class:Reason:Stack ->
            out(Port, io_lib:format("** ~p:~p\r\n   stack: ~p\r\n>> ",
                                    [Class, Reason, lists:sublist(Stack, 5)])),
            Bindings
    end.

out(Port, IoData) ->
    Port ! {self(), {command, iolist_to_binary(IoData)}},
    ok.
