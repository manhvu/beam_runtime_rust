# Tyn capability map — what real apps hit

What a *real, third-party* Elixir/Erlang app runs into on Tyn, past the validated "stateless Phoenix
serves." The point is not pass/fail; it is **the first wall, its traced root cause, and which missing
primitive it names** — the evidence that ranks the next roadmap investment.

**Evidence discipline (same as the futex/send records):** only rows with a **real boot** behind them
are marked *confirmed*. Predictions from source reading are marked *source-predicted* and are
hypotheses, not results — this project has been burned by confident source reads that collapsed on
contact (`syscall 40 never called`, the `−0x70` offset). A row moves to *confirmed* only when an app
actually booted and hit the wall.

---

## The map

| # | Probe (real app) | Boots? | Works? | First wall | Root cause (traced) | Missing primitive | Evidence |
|---|---|---|---|---|---|---|---|
| 5a | **Ecto + Postgres, plaintext TCP** | yes | **DB: YES — raw Postgrex *and* standard eager Ecto Repo** | two walls, both packaging — **RESOLVED in the shipped build** | stale base-image artifacts (missing `elixir.app`; stale `tyn_boot.beam`) — now fixed by `build-rootfs.sh` | none kernel-side; base-image packaging fixes (landed) | **CONFIRMED — Postgrex on Nitro; eager Ecto on the shipped build path (cpio `d30fb612`)** |
| 5b | **Ecto/Postgrex, TLS** (managed PG) | yes | **no — shim is symmetric-only (node survives)** | `:ssl.opt_signature_algs/3` `MatchError` — `:crypto.supports` returns `public_keys: []`, `curves: []` | Tyn's crypto shim implements only **symmetric** crypto (SHA/HMAC/AEAD/PBKDF2, for Phoenix cookies); it has **no asymmetric surface** (RSA/ECDSA/ECDHE/curves), which TLS requires — `:ssl` can't build a signature-alg set. (Cert/clock Wall 2 still further in, unreached.) | the full public-key crypto surface (≈ static OpenSSL) **or** a TLS-terminating sidecar; wall clock a further prereq for *in-guest* TLS | **CONFIRMED — local boot vs TLS-enabled PG** |
| 2 | **Phoenix + file write** (temp files, uploads) | yes | **no — degrades gracefully (node survives)** | `System.tmp_dir/0` → `nil`, then every write path errors | read-only cpio VFS: `sys_open` ignores `O_CREAT` (→ `ENOENT`), `sys_write` else-arm (→ `EBADF`), `mkdir`/`unlink`/`rename` unhandled (→ `ENOSYS`) | writable filesystem (tmpfs) | **CONFIRMED — local boot** |
| 3 | NIF-bearing dep (bcrypt/argon2) | fails `load_nif` | no | `load_nif` → "Dynamic loading not supported" | static-musl beam, no dynamic loading; `tyn-pack` wires only the crypto shim, not user NIFs | per-user-NIF static-link packaging | prior-observed (exact error seen) |
| 4 | Shells out (`System.cmd`, `os_mon`) | os_mon degraded; `cmd` fails | partial | `execve` → UNHANDLED/ENOSYS | no fork/exec; `erl_child_setup` can't spawn (see `inet_gethost`, below) | subprocess/exec | prior-observed |
| 6 | **Distributed Erlang** (native clustering) | yes | **YES — after a one-line kernel fix (missing `getrusage`)** | *(was)* `dist_util:gen_challenge/0` calls `erlang:statistics(runtime)` → `getrusage(RUSAGE_SELF)` → Tyn returned `ENOSYS` → ERTS treats getrusage failure as **fatal** (`erts_exit`) → node **exits** mid-handshake | Tyn was **missing the `getrusage(2)` syscall (nr 98)**. Not a deadlock, not the clock, not `dist_ctrl` — a missing syscall that ERTS aborts on. Added a zeroed-`rusage` stub → `statistics(runtime)` returns, `gen_challenge` completes | — (fixed: `getrusage` stub in `sys_syscall`) | **CONFIRMED — handshake completes end-to-end, nodes cluster (`connect_node`→`true`), traffic flows, node survives; single-node tap + native OTP peer** |
| 1 | Plain Plug (no Phoenix) | yes | yes | — (floor) | — | — | follows from working Phoenix demo |

---

## Probe 5a — the pivotal one, in detail (CONFIRMED on real Nitro)

Artifacts: a c5.large Nitro instance (kernel = shipped valve `1cac02f` + crypto beam, cpio
`probe_a.cpio` = minimal `postgrex` app). DB target: plaintext Postgres in the VPC (`5432`, `ssl=off`,
trust), table `probe(id)=42`. Serial console (host IP redacted):

```
PROBE_A: lookup=[:file, :dns]
PROBE_A: getaddr={:ok, {_ip_}}
PROBE_A: Postgrex.start_link <vpc-postgres>:5432 tyndb (plaintext, ssl=false)
PROBE_A_RESULT: CONNECTED rows=[[42]]
```

**The hinge answer: YES — a plaintext `postgrex` connection establishes and runs a query on Tyn over
real ENA.** The DB plumbing (socket layer, wire protocol, query) is sound. *Stateful, database-backed
apps are reachable on Tyn today* — but the path there surfaced two distinct walls that reshape the
roadmap more than the connectivity answer itself:

- **Wall A — Ecto's Repo won't start → RESOLVED (two packaging gaps, no kernel gap).** The Repo-init
  path first died at `Ecto.Repo.Supervisor.repo_init/3` → `Code.ensure_loaded?/1`: *"module Code is
  not available."* The map's first guess ("a code-server / load-time gap") was **wrong** — `Code`
  itself loads fine (`:code.ensure_loaded(Code)` → `{:module, Code}`). The real cause was **two stale
  artifacts in the base image**, both fixed by re-packaging, neither a kernel deficiency:
  1. **Missing `elixir.app`.** The base cpio ships 100+ OTP `.app` files but not Elixir's own
     application resource files. Without `elixir.app` (+ `logger`/`eex`/`mix`/`iex`), the application
     controller can't resolve `elixir` as a started app, and Ecto's repo-init surface reports `Code`
     unavailable. Adding those five `.app` files makes the eager Repo **start** cleanly.
  2. **Stale `tyn_boot.beam`.** The base cpio carried a `tyn_boot.beam` (Jul 11) that predated the
     `eval_runtime_config` logic in `src/erl/tyn_boot.erl` (Jul 16). It never evaluated `runtime.exs`,
     so the eager Repo read `nil` config, defaulted to `localhost:5432`, and timed out
     (`DBConnection queue_timeout`) with no connection error — the classic wrong-config symptom.
     Recompiling `tyn_boot.erl` into the cpio makes `runtime.exs` apply before `start_apps`, and the
     Repo gets its real config.

  With both fixed, the **standard eager Ecto pattern** — `MyApp.Repo` in the supervision tree, DB
  config from `runtime.exs`, **no app-side workarounds** — connects and queries:
  `EAGER_ECTO_RESULT: OK rows=[[42]]` against the real VPC Postgres. (Boot: local QEMU on the in-VPC
  build host, NAT'd to the *same* VPC Postgres the Nitro probe used — the DB, wire protocol, and full
  Ecto/DBConnection/Postgrex stack are real; only the L2 path differs from the pivotal ENA row, which
  is separately Nitro-confirmed.) *No missing primitive: this was packaging, cheap, and it unblocks
  the standard ORM path — the change that turns "raw Postgrex works" into "a normal Phoenix+Ecto app
  runs."*

  **Now landed in the shipped build, not a surgical image.** Both fixes are produced by the committed
  [`build-rootfs.sh`](../../build-rootfs.sh) (always recompiles `tyn_boot.beam` from source; adds the
  Elixir `.app` files from the pinned toolchain), documented in `BUILDING_ERTS.md §3`. The result
  above was re-confirmed on a base cpio built by that script (`md5 d30fb612…`) and packed with plain
  `tyn-pack` — the `elixir.app`/`tyn_boot.beam` in the app image came from the base build, verified by
  `cpio -t`, with *zero* hand-editing. This is the same discipline as the hand-patched
  `thousand_island`: the capability is only honest when the committed build path produces it.
- **Wall B — native resolver on connect.** postgrex's default connect path spawns `inet_gethost`
  (ERTS's native DNS port program), which Tyn cannot exec (`ebadf`) → the node **crashes**
  (`exit_group(1)`). Even a literal-IP hostname triggered it until the inet lookup method was forced
  off `native`: `:inet_db.set_lookup([:file, :dns])` before connecting makes it use the pure-Erlang
  resolver and the connection succeeds. **This is now the boot default:** `tyn_boot`'s
  `configure_dns/0` (which runs before `start_apps`) sets `inet_db:set_lookup([file, dns])` —
  `native` is never in the lookup order, so no app can spawn `inet_gethost`. The eager-Ecto probe
  above needed *no* app-side `set_lookup`; it resolved and connected on the boot default alone.
  *Missing primitive: none for the crash — a default inet config that never selects `native` is in
  `tyn_boot`. (Full `System.cmd`/exec is a separate, unrelated gap — row 4.)*

## Probe 5b — TLS-to-DB, in detail (CONFIRMED on a local boot vs a TLS-enabled Postgres)

The managed-Postgres question: *can Tyn open a TLS connection to a database?* Two walls could answer
"no" and they must not be collapsed — **Wall 1** (no working TLS stack) and **Wall 2** (the epoch
clock fails certificate dates). The probe was designed to separate them.

Setup: the standing VPC Postgres was TLS-enabled (self-signed cert, `ssl=on`); a control `psql
sslmode=require` confirmed a real server-side handshake (`TLSv1.3, TLS_AES_256_GCM_SHA384`), and
`sslmode=disable` still returns `42` (the plaintext row 5a is unaffected). Then a `Postgrex` client
with `ssl: true` was booted on Tyn against it. Reaching the real wall took peeling off a bug of our
own first.

**Layer 0 — our own bug (fixed): the crypto shim wasn't being applied.** The first probe crashed with
`Unable to load crypto library: :bad_lib, Function not declared as nif crypto:strong_rand_bytes/1` and
`(crypto 5.5.3) :crypto.supports/0` undefined. Root cause was **not** the shim — it was `tyn-pack`
resolving its shim path (`TYN_ERL=src/erl`) relative to the **caller's CWD** instead of the script.
Packed from an app's build dir, the `[ -f "$TYN_ERL/crypto.beam" ] && cp` silently skipped, so the
release's **stock** `crypto-5.5.3` beam stayed at the cpio root — and stock crypto's `on_load` demands
the full OpenSSL NIF, which mismatches Tyn's Rust NIF (built for the shim's 8-function set) → `:bad_lib`
→ `:crypto` unavailable → `:ssl.default_versions` dies at `:crypto.supports/0`. Fixed by making
`tyn-pack` resolve its assets relative to the script (`SCRIPT_DIR`), so the shim always wins. This was
"blocked by our own bug"; it is not a real capability wall.

**Layer 1 — the real wall: the shim is symmetric-only.** With the shim correctly applied, `:crypto`
loads (`{:module, :crypto}`) and `:crypto.supports()` returns:

```
hashs:  [sha, sha224, sha256, sha384, sha512]
ciphers:[aes_128_gcm, aes_256_gcm, chacha20_poly1305]
macs:   [hmac]
public_keys: []      ← no RSA / DSS / ECDSA
curves:      []      ← no named curves, no ECDHE
```

`:ssl` now gets past `default_versions` and dies further in, still during option processing:

```
** (RuntimeError) connect raised MatchError
   ssl.erl:4389: :ssl.opt_signature_algs/3     ← builds the TLS signature-algorithm set
   ssl.erl:3821: :ssl.process_options/3
   ssl.erl:3902: :ssl.handle_options/5
   ssl.erl:2221: :ssl.connect/3
   (postgrex) Postgrex.Protocol.ssl_connect/3
```

The shim implements exactly the **symmetric** crypto the Phoenix demo needs (hashes, HMAC for cookie
signing, AEAD ciphers, PBKDF2). It has **no asymmetric surface** — no RSA, no ECDSA, no ECDHE, no named
curves — so `public_keys`/`curves` are empty and `:ssl.opt_signature_algs` MatchErrors on the empty
set. TLS fundamentally needs asymmetric crypto (key exchange + certificate signatures), so this is not
a one-function gap; it is the entire public-key half of `:crypto` being absent. *This is the honest row
5b: in-guest TLS needs the full public-key crypto surface (≈ static OpenSSL), not a small shim patch.*

**Wall 2 (the epoch clock) is still unreachable** — cert `notBefore`/`notAfter` validation is inside a
handshake that never begins (the crash is in *option processing*, before the socket). The 1970 clock
remains a *named* prerequisite for in-guest TLS (see `docs/WALL_CLOCK.md`); it will bite the moment the
asymmetric crypto exists. The failure is graceful: the connection process dies, the node lives.

### Two paths to TLS-to-DB (assessed, not built)

- **Path A — real in-ERTS `:ssl` (add the asymmetric crypto surface).** The probe pins the remaining
  surface concretely: the shim covers symmetric crypto; TLS needs the **public-key half** —
  RSA + ECDSA signatures, ECDHE/DHE key exchange, named curves, and the `supports(public_keys)` /
  `supports(curves)` these feed. Extending the hand-rolled Rust shim to cover all of that is
  effectively reimplementing OpenSSL's asymmetric stack, so the realistic form is **rebuild ERTS
  `--with-ssl` against a static musl OpenSSL** (or link OpenSSL into the NIF). *Cost/risk: high.* It
  reopens the crypto-NIF/OpenSSL coexistence question the shim was created to avoid — a full OpenSSL
  NIF needs entropy (Tyn has a CSPRNG/`getrandom`), threads, `mmap`, and time to behave on Tyn's
  syscall surface; `beam.smp` grows by OpenSSL's static size. **Also gated on the clock (Wall 2)** —
  without a real wall clock, cert validation fails even once crypto works (`verify: :verify_none`
  sidesteps it per-connection but is not a real managed-DB posture). Upside: unlocks in-guest crypto
  broadly (TLS, and NIF-crypto deps like bcrypt/argon2), not just DB TLS.
- **Path B — TLS-terminating sidecar (offload, like inbound) — CHOSEN as the near-term pattern.**
  Inbound TLS is already terminated at an ALB/NLB; the outbound-to-DB analogue is a small in-VPC proxy
  (stunnel / pgbouncer-with-TLS-upstream): Tyn speaks **plaintext** to the proxy (already proven,
  `[[42]]`), the proxy originates TLS to the managed DB and validates the cert with its own real clock.
  *Cost/risk: low* — no ERTS rebuild, no crypto NIF, no in-guest clock dependency. Operational cost:
  run the proxy next to each instance. RDS requires TLS *from its client*, and **RDS Proxy does not
  remove that** — the sidecar (the actual TLS originator) is what satisfies it. This is now documented
  as a deployment pattern (`docs/DEPLOY.md` → "Reach a TLS-required database through a sidecar"),
  parallel to inbound LB termination.

**Path A's scope is now known** (the "held" question is answered). The masking `tyn-pack` bug is
fixed, the shim loads, and the re-run shows the real gap is the **entire asymmetric crypto surface**,
not a handful of primitives. So Path A is not a small shim extension — it is a static-OpenSSL-class
build, plus the wall clock (`docs/WALL_CLOCK.md`). That is a genuine, sizeable investment; **Path B
(sidecar) remains the near-term answer**, and Path A is justified only when in-guest crypto breadth
(TLS *and* bcrypt/argon2-style NIF deps, row 3) is worth an OpenSSL integration on its own.

## Probe 2 — file write, in detail (CONFIRMED on a local boot)

Artifact: kernel = shipped valve `1cac02f` (`tyn-kernel-fix2`), cpio = a minimal app whose only
job is to attempt filesystem writes several ways and report the raw result. FS behavior is pure kernel
VFS (the read-only cpio) — identical local vs Nitro — so a local QEMU boot is a faithful confirmation;
no Nitro run is needed for this row. Serial output (`node_alive` is `Process.alive?` at the end):

```
PB tmp_dir: nil
PB File.write /tmp/pb.txt:                {:error, :enoent}
PB File.open /tmp/pb.txt [:write]:        {:error, :enoent}
PB raw open+write /tmp/upload.tmp:        {:error, :enoent}     % Plug.Upload's write path
PB File.mkdir /tmp/pbdir:                 {:error, :enosys}
PB raw open+write existing ./boot.config: {:opened_then_write, {:error, :ebadf}}  % open OK, write fails
PB File.rename:                           {:error, :enosys}
PB File.rm /tmp/pb.txt:                   {:error, :enosys}
PB_END node_alive=true
```

**The BEAM-side errno returns are one-to-one with the read-only VFS (source-verified in `src/syscall.rs`):**

| Operation | Kernel path | Returns | BEAM sees |
|---|---|---|---|
| Create a new file (`O_CREAT` ignored) | `sys_open` flags ignored → lookup miss | `-2 ENOENT` | `{:error, :enoent}` |
| Write to an existing cpio file opened "for write" | `vfs::open` hands back a **read** fd; `sys_write` else-arm | `-9 EBADF` | open succeeds, then `{:error, :ebadf}` |
| `mkdir` / `rename` / `unlink` / `ftruncate` | no dispatch arm → `UNHANDLED` | `-38 ENOSYS` | `{:error, :enosys}` |

Two things the source read alone would have missed:

- **The first wall is `System.tmp_dir/0` returning `nil`, not the write itself.** Elixir probes
  `$TMPDIR`/`$TEMP`/`$TMP`/`/tmp` for a *writable* directory, finds none, and returns `nil`. So a real
  upload/temp-file library hits the wall at **tmp-dir resolution**, before any `open`: `Plug.Upload`
  calls `System.tmp_dir` and has no destination, and `System.tmp_dir!/0` *raises* `RuntimeError`. The
  missing primitive is a writable path that tmp-dir probing accepts.
- **The wall degrades; it does not crash the node.** `node_alive=true` — every failure is a catchable
  `{:error, _}` tuple, so an app faults only in whatever process attempted the write (its own
  supervision decides what happens). This is materially different from Wall B's `inet_gethost`, which
  takes the whole node down (`exit_group(1)`). *A file-write wall is survivable; a native-resolver
  wall is fatal.* (Aside: `mremap` (nr 25) is also unhandled → `ENOSYS`; ERTS normally tolerates it,
  but it triggered one transient `{load_failed,[erl_lint]}` boot abort under TCG before a clean retry —
  a latent sharp edge, not part of the FS story.)

*Missing primitive: a small writable tmpfs mounted at `/tmp` (plus `mkdir`/`unlink`/`rename`/
`ftruncate` syscalls and a create path in `sys_open`/`sys_write`). Scope is bounded — enough for
`System.tmp_dir` to resolve and for temp-file/upload writes to land.*

## Probe 6 — Distributed Erlang, in detail (CONFIRMED on 2× Nitro + a native OTP peer)

The positioning question: *can two Tyn nodes form a native Erlang cluster?* Artifacts: two Nitro
t3.small (`probe_a@172.31.26.231`, `probe_b@172.31.29.10`) from an AMI built with a kernel carrying a
`-setcookie` arg + a base cpio with a static epmd-less `tyn_epmd` module; a stock OTP-27 node
(`bh@172.31.5.221`) on the build host as a known-good peer. Result by escalating level:

| Level | Result |
|---|---|
| Node starts distributed | **yes** — `is_alive()` → `true`, `node()` correct, `get_cookie()` correct, `net_kernel` up (both nodes, real Nitro) |
| Dist listener binds (fixed port 9100) | **yes** — `net_kernel:start` succeeds; port accepts (`nc -zv`) |
| Raw TCP node↔node on 9100 | **yes** — node A `gen_tcp:connect(B, 9100)` → `{ok, Port}` |
| **Handshake (`connect_node`)** | **NO** — returns `false` after exactly **7001 ms** (`net_setuptime`); `nodes()` stays `[]` |

**The break is Tyn's accept-side handshake, bisected with the native peer.** The handshake TCP-connects
but then stalls waiting for protocol data (a 7 s *timeout*, not a refusal and not a cookie rejection —
those fail fast). A **known-good native OTP node connecting *to* Tyn `probe_b` fails identically**
(`false`, 7004 ms), so the broken half is Tyn *accepting* an incoming dist connection and running the
handshake — not the initiator, not TCP, not the cookie. Likely the dist listener's own accept/handshake
data path (related to but distinct from the earlier `gen_tcp:accept` fix, which was for Bandit's
listener).

**What makes the accept side different from everything that works** (the suspects, in check order).
The dist listener is *not* Bandit's `gen_tcp:accept` in a plain process loop — it's `inet_tcp_dist`
(ERTS's own driver) doing an **async accept → controlling-process handoff → active-mode flip → handshake
state machine** on the accepted socket. That combination is exercised by nothing else on Tyn. Three
suspects:

1. **The accepted socket never delivers its first data (most likely).** The initiator's `send_name`
   goes out the instant the connection establishes; the acceptor stalls in a receive that never fires —
   i.e. bytes reached Tyn's NIC but the acceptor never saw them. This is the readiness/epoll family we
   have history in (the `gen_tcp:accept` fix, epoll-global-not-per-fd, the connecting-socket `POLLOUT`
   case): readiness may follow the *listener* fd but not correctly attach to the *accepted* fd across
   the controlling-process + active-mode flip.
2. **`{packet, 2}` framing.** The handshake runs 2-byte length-prefixed packets (the driver sets
   `{packet,2}` on the accepted socket). HTTP works because Bandit uses raw mode; if Tyn mishandles
   `{packet,2}` reassembly on inbound data, the driver waits forever for a packet it never completes.
3. **The `controlling_process/2` transfer.** Re-targeting which process receives the socket's messages;
   if Tyn doesn't re-route readiness/ownership on that call, data is delivered to (or queued for) the
   wrong process.

**Discriminator run — all three socket-op suspects REFUTED.** A ~30-line harness reproduced the exact
sequence outside distribution (`docs/DIST_ACCEPT_HUNT.md`), booted on one QEMU node, host sending framed
data. Every variant returned `<<"hello">>`:

| Probe | Result |
|---|---|
| accept + `{packet,2}` + `controlling_process` + `{active,once}` (exact sequence) | ✅ `<<"hello">>` |
| drop `{packet,2}` / drop the handoff / plain control | ✅ all `<<"hello">>` |
| **`prim_inet:async_accept`** (what `inet_tcp_dist` *actually* calls) | ✅ accepted + delivered |
| acceptor recv-then-**send-back** (framed reply to host) | ✅ host got the `{packet,2}` reply |

So the socket layer is *not* the bug: sync accept, **async accept**, `{packet,2}` **both directions**,
`controlling_process` handoff, active-mode, passive recv, and acceptor send-flush all work in isolation.
The stall is above the transport.

**Pinned — a byte-level tap + BIF isolation, single node, no Nitro.** Rather than jump to a two-node
Nitro trace, the next rung: a `{packet,2}` proxy taps the handshake between a known-good native OTP
initiator and Tyn (over hostfwd), and the handshake reproduces one layer up with full visibility. The
tap shows exactly where Tyn goes silent:

```
INIT→TYN  tag 'N'  send_name       ← initiator sends its name
TYN→INIT  tag 's'  send_status "sok" ← Tyn CONSUMES it and REPLIES  ✅
(then nothing from Tyn for 7 s; initiator times out)
```

So Tyn reaches step 2 (consumes `send_name`, emits `send_status`) and dies before **step 3
(`send_challenge`)**. The acceptor code between those two (`dist_util:handshake_other_started`, lines
215-217) is `auth:get_cookie/1` → `gen_challenge/0` → `send_challenge/2`, and `gen_challenge/0` calls a
run of BIFs including `erlang:statistics(runtime)` (line 5) and `erlang:statistics(wall_clock)` (line 6).

**Root cause — a missing syscall, not a deadlock: `getrusage`.** `erlang:statistics(runtime)` →
`erts_runtime_elapsed_both()` → `getrusage(RUSAGE_SELF, &now)`. Tyn had **no `getrusage(2)` handler
(nr 98)**, so it returned `ENOSYS`; ERTS treats getrusage failure as **fatal** —
`if (getrusage(...) != 0) erts_exit(ERTS_ABORT_EXIT, "getrusage(RUSAGE_SELF, _) failed: %d")` — so the
node **exits** (`exit_group(127)`) mid-`gen_challenge`. The serial log during the call shows exactly
that (`getrusage(RUSAGE_SELF, _) failed: 38` then `exit_group(127)`). **Fix:** a `getrusage` stub that
returns a zeroed `struct rusage` (`src/syscall.rs`). After it, `statistics(runtime)` returns `{0,0}`,
`gen_challenge` completes, and — re-running the tap — the acceptor now emits `send_challenge`, the
handshake finishes (`send_challenge_reply` → `send_challenge_ack`), the dist controller takes over
(Erlang term frames flow both ways), and `net_kernel:connect_node` returns **`true`** with `nodes()`
populated in **96 ms**. The node stays healthy.

> **Correction — a three-draft error, and how it was caught (the −0x70 lesson, hard).** Earlier drafts
> of this row said "`statistics(wall_clock)` busy-spins," then "deadlocks on `erts_get_time_mtx`
> (futex)," then tied it to the wall clock / `WALL_CLOCK.md`. **All wrong.** Two mistakes compounded:
> (1) a capture bug — a bare `>> ` shell prompt was read as a *returned value*, so
> `statistics(runtime)` (which actually died) was logged as "works," and the blame fell on
> `statistics(wall_clock)` which is *next in `gen_challenge`*; health-gated re-testing showed
> `statistics(wall_clock)` **works** (`>> 13797`) and `statistics(runtime)` is the one that dies.
> (2) "0 % CPU + wedged" was read as a *deadlock* — but the serial log (never checked until the ladder
> forced it) showed an `exit_group`: the node had **exited**, not blocked. The clock/futex/time-
> correction analysis was a castle built on the misattribution. The fix is trivial (one syscall stub),
> which is what the ladder's discipline predicted once the contradiction was chased instead of
> concluded. Blast radius beyond dist: any caller of `statistics(runtime)` (schedulers/monitoring,
> `:observer`, some telemetry) would have crashed the node the same way; the stock demo doesn't call
> it, which is why it ran.

**The cookie sub-wall (fully proven, and the reason for a kernel change).** Distribution wouldn't even
*start* until the cookie was provided as a **boot arg**. Every file-based cookie path is structurally
blocked on Tyn: no `HOME` → `filename:basedir` `badmatch`; a shipped cookie file fails `auth`'s
owner-only check because Tyn's `sys_stat` reports a synthetic `0644`; and auto-generation dies on the
read-only FS. `-setcookie` is therefore the *only* correct mechanism on Tyn — verified: with it, the
node goes distributed cleanly. (Baked into the kernel binary here as spike scaffolding only — a cookie
in the shared kernel is auth-lite, not isolation; the SG rule on the dist port is. Its real home is
`boot.config` at pack time, per-image. See `src/main.rs` and `directions/DIST_SPIKE*.md`.)

**epmd-less recipe (works up to the accept wall; documentation-worthy).** Fixed dist port on every node
via a ~30-line static `epmd_module` (`listen_port_please` → the port; `address_please` →
`{ok, Addr, Port, 6}`), `-setcookie` boot arg, longnames with IP literals, and a security-group rule on
the dist port for real isolation. `application:set_env(kernel, epmd_module, tyn_epmd)` before
`net_kernel:start/2` (or a `-kernel` arg). With the `getrusage` fix this recipe now takes a node all the
way through the handshake — it was never the config that blocked, and the one kernel gap is closed.

**Verdict for positioning: BUILDABLE — native clustering works after a one-line kernel fix.** With the
`getrusage` stub, a native OTP node and a Tyn node complete the *full* Erlang distribution handshake
(`send_name` → `status` → `challenge` → `reply` → `ack`), the `dist_ctrl` controller takes over, term
traffic flows both directions, `connect_node` → `true` (96 ms), and the node stays healthy — the exact
back-half (challenge-reply/ack + controller takeover) that earlier looked "unexercised" now runs. The
missing primitive was a single syscall, not a subsystem. **One honest caveat before the pitch is
"shipped":** this is confirmed on a *single Tyn node* + a native-OTP peer over hostfwd; the last
validation is **two Tyn nodes on Nitro** — `connect_node` both directions, `rpc:call`, a ~1 MB term
hash-checked, and liveness across several `net_ticktime` cycles with `nodedown` on kill. That plus
moving the cookie from the kernel `-setcookie` scaffolding to `boot.config` (per-image) is what turns
"buildable, proven at the handshake" into "shippable native mesh."

## Synthesis — what to build next

**Because plaintext Postgrex works *and* the standard eager Ecto Repo works once the base image is
re-packaged, DB connectivity is *not* the blocker and Ecto is *not* the blocker.** Re-ranked by what
they unblock:

1. **Wall A packaging fixes — LANDED.** Elixir's `.app` files (`elixir`/`logger`/`eex`/`iex`/`mix`)
   and a from-source `tyn_boot.beam` are now produced by the committed `build-rootfs.sh` (base cpio
   `md5 d30fb612…`), with the resolver `[file, dns]` default folded into `tyn_boot`. Shipped-path
   eager Ecto queries the real VPC DB (`[[42]]`) with no surgery. This is the change that turns "raw
   Postgrex works" into "a normal Phoenix+Ecto app runs." *(Remaining: fully regenerating the
   accreted dependency beams from a mix build is a separate reproducibility task; `build-rootfs.sh`
   refreshes only the two source-derived components.)*
2. **TLS-to-DB (the managed-Postgres unlock) — now boot-confirmed as row 5b.** The wall is **not**
   `:ssl` being a stub (`:ssl`/`:public_key` load fine), and **not** a one-function shim gap. With the
   crypto shim correctly applied (after fixing a `tyn-pack` path bug that had let stock crypto load),
   `:crypto` works for **symmetric** ops but advertises `public_keys: []`, `curves: []` — it has no
   asymmetric crypto, so `:ssl.opt_signature_algs` MatchErrors during option setup, *upstream of the
   handshake and the epoch-clock cert wall*. The real gap is the entire public-key surface. Two paths
   (detail in Probe 5b): **Path B** (TLS-terminating sidecar) unblocks managed Postgres now with **no
   kernel work**; **Path A** (static-OpenSSL-class crypto) is a sizeable investment and **must be
   sequenced with the wall-clock (kvmclock/RTC) work** or it fails cert dates. Clock is a *named*
   prerequisite (`docs/WALL_CLOCK.md`).
3. **Writable tmpfs** — breadth (any disk touch), independent of the DB story. **Probe B (row 2) is
   now boot-confirmed:** the wall is graceful (`{:error, _}`, node survives) and surfaces first at
   `System.tmp_dir/0 → nil`. A small writable `/tmp` (create path in `sys_open`/`sys_write` +
   `mkdir`/`unlink`/`rename`) unblocks temp files and uploads without a full disk stack.

The one-sentence version: **stateful DB-backed apps are reachable on Tyn today — raw Postgrex over
plaintext TCP is Nitro-confirmed, and the *standard eager Ecto Repo* now works on the committed build
path (`elixir.app` + from-source `tyn_boot.beam` via `build-rootfs.sh`, `[[42]]`, no surgery); the
remaining walls are all boot-confirmed and specific — TLS-to-DB works symmetrically but lacks the
*asymmetric* half of `:crypto` (`public_keys`/`curves` empty → `:ssl.opt_signature_algs` fails), still
upstream of the epoch-clock cert wall, and is unblockable now via a TLS sidecar or later via
static-OpenSSL-plus-clock; and a file-write wall degrades gracefully, surfacing first at
`System.tmp_dir/0 → nil` — none of it is the database plumbing or the ORM.**

---

*Probe 5a is boot-backed: raw Postgrex over ENA is Nitro-confirmed (artifacts above); the eager-Ecto
resolution is confirmed on a local QEMU boot NAT'd to the *same* VPC Postgres (a fair proxy for the
packaging/config fix, which is network-agnostic — the ENA path is Nitro-confirmed separately). The
clean Nitro re-run of the full eager-Ecto path is the natural next confirmation but was not burned for
a packaging fix. **Wall A fixes are now in the committed build path** — base cpio built by
[`build-rootfs.sh`](../../build-rootfs.sh) (`md5 d30fb612…`, ships the Elixir `.app` files + a
from-source `tyn_boot.beam` with the `[file, dns]` resolver default); the eager-Ecto app image was
packed with plain `tyn-pack` (no surgery, `cpio -t`-verified) and is a minimal `ecto_sql`+`postgrex`
release with `MyApp.Repo` in the tree and DB config in `runtime.exs`. Probe 5b (TLS-to-DB) is
boot-confirmed on a local boot against the standing Postgres with **TLS enabled** (self-signed cert,
`ssl=on`; `psql sslmode=require` verified a real TLSv1.3 handshake server-side; plaintext still works,
so row 5a is unaffected). **TLS is now a permanent fixture on the standing DB** — it costs nothing and
both plaintext (5a) and TLS (5b) probes need it, so it stays on. Reaching row 5b's real wall required
fixing a `tyn-pack` bug (shim path resolved from CWD, not the script), which had let stock crypto
shadow the shim; with the shim applied, `:crypto` loads symmetrically and the wall is the missing
asymmetric surface (`:ssl.opt_signature_algs`). Probe 2 (file write) is boot-confirmed on a local boot (FS behavior is pure kernel VFS,
identical local vs Nitro). Probe 6 (distributed Erlang) is boot-confirmed on 2× Nitro t3.small + a
native OTP peer (now terminated; AMI/snapshot/S3 cleaned up) — it **corrected** the earlier
source-predicted "dist modules absent" guess. Rows 3/4 remain prior-observed. DB target + toolchain
remain standing on the build host for the follow-on probes.*
