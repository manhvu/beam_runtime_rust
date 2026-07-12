%% Generic app launcher for Tyn (Track 1, Phase 1c).
%%
%% The kernel's -eval is now the fixed, app-agnostic `tyn_boot:start()`. What
%% actually boots is decided by `boot.config` *inside the cpio* — so one kernel
%% binary boots whatever app it's handed. This is the whole point of Track 1:
%% deploy a different app by swapping the cpio, not by rebuilding the kernel.
%%
%% boot.config is a file of Erlang terms at the cpio root:
%%
%%   {apps, [telemetry, jason]}.        %% ensure_all_started, in order (optional)
%%   {plug, bench_plug}.                %% App A: hand this Plug to Bandit
%%   {port, 8080}.                      %% listener port (optional, default 8080)
%%
%% or, for an app that isn't a Bandit Plug (App B — a plain gen_tcp responder):
%%
%%   {apps, []}.
%%   {start_mfa, {appb_responder, start, [8080]}}.   %% apply(M,F,A) to start it
%%   {port, 8080}.
%%
%% Order of operations (matters):
%%   1. Start the serial + TCP eval shells FIRST, so a failing app still leaves
%%      a debuggable instance (a deploy tool whose failure mode is "unreachable
%%      brick" is unusable).
%%   2. Read boot.config with erl_prim_loader:get_file/1 — the *proven* loader
%%      path (it's how every .beam already loads here); not file:consult/1.
%%   3. Parse with erl_scan + erl_parse (both already proven by the eval shell).
%%   4/5. ensure_all_started each app, then start the listener.
%%   6. Print `tyn_boot: started <App> on port <Port>` and keep printing the
%%      existing `phoenix_listening` marker (deploy/AMI/sweep scripts grep it).
%%
%% Failure: print `tyn_boot: FAILED <reason>` and DO NOT halt — the shells stay
%% up so the instance is debuggable. Absent boot.config (the embedded-cpio
%% fallback from 1b, which ships no boot.config) falls back to the demo defaults
%% and prints `tyn_boot: no boot.config, using defaults`, so that path is
%% unchanged.

-module(tyn_boot).
-export([start/0]).

start() ->
    %% 1. Shells first — reachable even if the app fails to start. The
    %%    "serial_shell ready" quiet-mode marker is deliberately withheld until
    %%    the very end (on success) so kernel logs stay visible through app
    %%    startup and, on failure, stay visible for debugging.
    start_shells(),
    %% 2/3/4/5. Config-driven app + listener, guarded so a failure can't take
    %%    down the boot process (and with it, cleanliness of the shells).
    try
        apply_config(load_config()),
        %% Success: final quiet-mode marker (see src/syscall.rs — printing
        %% "serial_shell ready" flips the serial console quiet).
        io:format("serial_shell ready~n")
    catch
        Class:Reason:Stk ->
            io:format("tyn_boot: FAILED ~p:~p~n  stack: ~p~n",
                      [Class, Reason, lists:sublist(Stk, 5)])
            %% No halt, no quiet marker: shells remain up and verbose.
    end,
    %% Park the boot process forever; Bandit and the shells run in their own
    %% processes. (-eval completing would not stop the node, but parking keeps
    %% this process around as an obvious anchor.)
    receive _ -> ok after infinity -> ok end.

start_shells() ->
    catch tcp_shell:start(9090),
    catch serial_shell:start(),
    io:format("shell_listening 9090~n").

%% Returns a proplist of config terms. Absent boot.config -> demo defaults.
%% Malformed boot.config raises (caught by start/0 -> FAILED, no halt).
load_config() ->
    case get_config_bin() of
        {ok, Bin} ->
            case parse_terms(binary_to_list(Bin)) of
                {ok, Terms} ->
                    io:format("tyn_boot: boot.config loaded (~p terms)~n",
                              [length(Terms)]),
                    Terms;
                {error, R} ->
                    error({boot_config_parse, R})
            end;
        error ->
            io:format("tyn_boot: no boot.config, using defaults~n"),
            defaults()
    end.

%% The demo defaults reproduce the pre-1c hardcoded -eval: start telemetry, then
%% Bandit with bench_plug on 8080. (The old eval also *called*
%% ensure_all_started(jason), but ignored its result — jason cannot start as an
%% application here because its `elixir` app-dependency has no findable
%% elixir.app, yet 'Elixir.Jason':encode! works fine as a plain module call. So
%% jason is intentionally NOT in the app list; see start_apps/1's lenient
%% handling. The old eval likewise did not start a `phoenix` application —
%% bench_plug is a plain Plug — so neither do we.)
defaults() ->
    [{apps, [telemetry]}, {plug, bench_plug}, {port, 8080}].

get_config_bin() -> try_paths(["boot.config", "/boot.config", "./boot.config"]).

try_paths([]) -> error;
try_paths([P | Ps]) ->
    case erl_prim_loader:get_file(P) of
        {ok, Bin, _Full} -> {ok, Bin};
        error -> try_paths(Ps)
    end.

%% Scan the whole file, then split the token stream on each dot and parse_term
%% every chunk. file:consult/1 would be shorter but routes through the unproven
%% file-server path; erl_scan/erl_parse are the proven primitives.
parse_terms(Str) ->
    case erl_scan:string(Str) of
        {ok, Tokens, _} -> parse_tokens(Tokens, []);
        {error, Info, _} -> {error, {scan, Info}}
    end.

parse_tokens([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_tokens(Tokens, Acc) ->
    case take_term(Tokens, []) of
        {ok, TermToks, Rest} ->
            case erl_parse:parse_term(TermToks) of
                {ok, Term} -> parse_tokens(Rest, [Term | Acc]);
                {error, R} -> {error, {parse, R}}
            end;
        {more, _} ->
            {error, missing_dot}
    end.

%% Collect tokens up to and including the next dot (parse_term wants the dot).
take_term([{dot, _} = D | Rest], Acc) -> {ok, lists:reverse([D | Acc]), Rest};
take_term([T | Rest], Acc) -> take_term(Rest, [T | Acc]);
take_term([], Acc) -> {more, lists:reverse(Acc)}.

apply_config(Terms) ->
    Port = proplists:get_value(port, Terms, 8080),
    start_apps(proplists:get_value(apps, Terms, [])),
    case proplists:get_value(start_mfa, Terms) of
        {M, F, A} when is_list(A) ->
            io:format("tyn_boot: starting via ~p:~p/~p~n", [M, F, length(A)]),
            apply(M, F, A),
            started(M, Port);
        undefined ->
            case proplists:get_value(plug, Terms) of
                undefined ->
                    %% No explicit listener directive. This is the preferred
                    %% form for a Mix release (Phase 2): {apps,[my_app]} started
                    %% above, and my_app's own supervision tree brings up its
                    %% listener (e.g. Bandit). Nothing more for tyn_boot to start.
                    started(apps, Port);
                Plug ->
                    %% 1c shorthand: hand a bare Plug module to Bandit ourselves.
                    {ok, _} = 'Elixir.Bandit':start_link(
                                [{plug, Plug}, {port, Port}, {scheme, http}]),
                    started(Plug, Port)
            end
    end.

started(What, Port) ->
    io:format("tyn_boot: started ~p on port ~p~n", [What, Port]),
    %% Keep the historical marker that every deploy/AMI/sweep script greps for.
    io:format("phoenix_listening~n").

%% Lenient on purpose. The pre-1c -eval called ensure_all_started/1 but ignored
%% the result, and the demo served fine even when a dependency app (jason ->
%% elixir) could not start, because the actual work is done by module calls, not
%% by a running application. So a failed app is a WARNING, not fatal — mirroring
%% that tolerance. The thing that must truly come up is the listener, and its
%% failure (in apply_config/1) is what raises -> tyn_boot: FAILED.
start_apps([]) -> ok;
start_apps([App | Rest]) ->
    case application:ensure_all_started(App) of
        {ok, _}    -> io:format("tyn_boot: app ~p started~n", [App]);
        {error, R} -> io:format("tyn_boot: warning: app ~p did not start: ~p~n",
                                 [App, R])
    end,
    start_apps(Rest).
