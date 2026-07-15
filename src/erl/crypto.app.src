%% Library application (NO {mod,...} key) so application:ensure_all_started(crypto)
%% — which plug triggers via its dependency list — succeeds without a supervisor.
%% Goes into the cpio root as `crypto.app`.
{application, crypto,
 [{description, "Tyn RustCrypto shim (unreviewed)"},
  {vsn, "5.4"},
  {modules, [crypto]},
  {registered, []},
  {applications, [kernel, stdlib]}]}.
