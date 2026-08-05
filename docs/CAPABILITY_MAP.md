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
| 5b | **Ecto/Postgrex, TLS** (managed PG) | yes | **no — crypto NIF incomplete (node survives)** | `:ssl.connect` → `:crypto.supports/0` `UndefinedFunctionError` at option setup | Tyn's crypto *shim* declares a narrow NIF surface (no `strong_rand_bytes/1`); real `:crypto`'s `on_load` fails `:bad_lib` → `:crypto` unavailable; `:ssl` needs it *before* any handshake, so cert/clock (Wall 2) is never reached | full crypto NIF (OpenSSL static) **or** a TLS-terminating sidecar; wall clock is a further prereq for *in-guest* TLS | **CONFIRMED — local boot vs TLS-enabled PG** |
| 2 | **Phoenix + file write** (temp files, uploads) | yes | **no — degrades gracefully (node survives)** | `System.tmp_dir/0` → `nil`, then every write path errors | read-only cpio VFS: `sys_open` ignores `O_CREAT` (→ `ENOENT`), `sys_write` else-arm (→ `EBADF`), `mkdir`/`unlink`/`rename` unhandled (→ `ENOSYS`) | writable filesystem (tmpfs) | **CONFIRMED — local boot** |
| 3 | NIF-bearing dep (bcrypt/argon2) | fails `load_nif` | no | `load_nif` → "Dynamic loading not supported" | static-musl beam, no dynamic loading; `tyn-pack` wires only the crypto shim, not user NIFs | per-user-NIF static-link packaging | prior-observed (exact error seen) |
| 4 | Shells out (`System.cmd`, `os_mon`) | os_mon degraded; `cmd` fails | partial | `execve` → UNHANDLED/ENOSYS | no fork/exec; `erl_child_setup` can't spawn (see `inet_gethost`, below) | subprocess/exec | prior-observed |
| 6 | oban / distribution | single-node yes; dist fatal | — | epmd / distributed Erlang absent | no epmd, no `inet_dist` in source | distributed Erlang / epmd | source-predicted |
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
with `ssl: true` was booted on Tyn against it. The `Postgrex.Protocol` connection process crashed at
`{:connect, :init}`:

```
[error] Unable to load crypto library: :bad_lib, Function not declared as nif crypto:strong_rand_bytes/1
[error] :gen_statem (Postgrex.Protocol) terminating
  ** (RuntimeError) connect raised UndefinedFunctionError
     (crypto 5.5.3) :crypto.supports/0
     ssl.erl:3958: :ssl.default_versions/1   ← :ssl asks :crypto which TLS versions exist
     ssl.erl:3947: :ssl.opt_versions/3
     ssl.erl:3815: :ssl.process_options/3
     ssl.erl:3902: :ssl.handle_options/5     ← still in OPTION SETUP; no socket, no handshake yet
```

A direct `:ssl` probe corroborates: `:ssl` and `:public_key` load and `ssl:connect/4` is exported,
but `:code.ensure_loaded(:crypto)` → `{:error, :on_load_failure}` and `:crypto.supports()` →
*"module :crypto is not available."*

**Wall 1, precisely: the crypto NIF is a partial shim, not `:ssl` being a stub.** ERTS was built
`--without-ssl`, so there is no OpenSSL-linked crypto NIF. Tyn ships a crypto *shim* that declares
just the NIF surface the demo needs (cookie/session signing); it does **not** declare
`crypto:strong_rand_bytes/1` (and the rest), so the stock `crypto.beam`'s `on_load` fails with
`:bad_lib` and `:crypto` is unavailable process-wide. `:ssl` calls `:crypto.supports/0` in
`:ssl.default_versions` during **option processing** — the very first step of `:ssl.connect`, before a
socket is opened. So TLS fails at setup.

**Therefore Wall 2 (the epoch clock) is currently unreachable.** Certificate `notBefore`/`notAfter`
validation lives deep inside a TLS handshake that never begins. The 1970 clock is a real, *named*
prerequisite for any in-guest TLS — it will fail cert dates the moment crypto works — but it cannot be
observed until Wall 1 is lifted. The failure is graceful: the connection process dies, the node lives.

### Two paths to TLS-to-DB (assessed, not built)

- **Path A — real in-ERTS `:ssl` (fix `:crypto`).** Rebuild ERTS `--with-ssl` (or complete the crypto
  NIF) linked against a **static musl OpenSSL**, so `:crypto`'s `on_load` succeeds and `:ssl` works
  in-guest. *Cost/risk: high.* It reopens the crypto-NIF/OpenSSL coexistence question the shim was
  created to avoid — a full OpenSSL NIF needs entropy (Tyn has a CSPRNG/`getrandom`), threads, `mmap`,
  and time to behave on Tyn's syscall surface; `beam.smp` grows by OpenSSL's static size. **Also gated
  on the clock (Wall 2)** — without a real wall clock, cert validation fails even once crypto works
  (mitigable per-connection with `verify: :verify_none`, but that is not a real managed-DB posture).
  Upside: unlocks in-guest crypto broadly (TLS, and NIF-crypto deps like bcrypt), not just DB TLS.
- **Path B — TLS-terminating sidecar (offload, like inbound) — CHOSEN as the near-term pattern.**
  Inbound TLS is already terminated at an ALB/NLB; the outbound-to-DB analogue is a small in-VPC proxy
  (stunnel / pgbouncer-with-TLS-upstream): Tyn speaks **plaintext** to the proxy (already proven,
  `[[42]]`), the proxy originates TLS to the managed DB and validates the cert with its own real clock.
  *Cost/risk: low* — no ERTS rebuild, no crypto NIF, no in-guest clock dependency. Operational cost:
  run the proxy next to each instance. RDS requires TLS *from its client*, and **RDS Proxy does not
  remove that** — the sidecar (the actual TLS originator) is what satisfies it. This is now documented
  as a deployment pattern (`docs/DEPLOY.md` → "Reach a TLS-required database through a sidecar"),
  parallel to inbound LB termination.

**Path A's decision is held** until the crypto shim's `:bad_lib` is fixed. Right now the shim fails at
the *first* missing declaration (`strong_rand_bytes/1`); we do not yet know the *full* remaining crypto
surface `:ssl` needs (cipher/KDF/RNG primitives), so we cannot size Path A honestly. The next-session
sequence resolves this: **declare the missing NIF function(s) in the shim → re-run Probe 5b → read the
*next* wall** (another missing primitive, or the handshake finally reaching the epoch-clock cert wall).
Only then is Path A (full static-OpenSSL crypto NIF) a decision with real numbers behind it — and it
remains gated on the wall clock either way (see `docs/WALL_CLOCK.md`).

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
   `--without-ssl`-means-`:ssl`-is-a-stub; `:ssl`/`:public_key` load fine. It is the **crypto NIF
   shim** being incomplete (no `strong_rand_bytes/1` → `:crypto` `on_load` fails `:bad_lib`), so
   `:ssl.connect` dies at `:crypto.supports/0` during option setup — *upstream of the handshake and the
   epoch-clock cert wall, which is therefore unreachable*. Two paths (detail in Probe 5b): **Path B**
   (TLS-terminating sidecar) unblocks managed Postgres now with **no kernel work**; **Path A** (real
   in-ERTS `:ssl` via static OpenSSL) is the larger crypto investment and **must be sequenced with the
   wall-clock (kvmclock/RTC) work** or it fails cert dates. Clock is now a *named* prerequisite.
3. **Writable tmpfs** — breadth (any disk touch), independent of the DB story. **Probe B (row 2) is
   now boot-confirmed:** the wall is graceful (`{:error, _}`, node survives) and surfaces first at
   `System.tmp_dir/0 → nil`. A small writable `/tmp` (create path in `sys_open`/`sys_write` +
   `mkdir`/`unlink`/`rename`) unblocks temp files and uploads without a full disk stack.

The one-sentence version: **stateful DB-backed apps are reachable on Tyn today — raw Postgrex over
plaintext TCP is Nitro-confirmed, and the *standard eager Ecto Repo* now works on the committed build
path (`elixir.app` + from-source `tyn_boot.beam` via `build-rootfs.sh`, `[[42]]`, no surgery); the
remaining walls are all boot-confirmed and specific — TLS-to-DB fails at an incomplete *crypto NIF*
(not `:ssl`), upstream of the epoch-clock cert wall, and is unblockable now via a TLS sidecar or later
via static-OpenSSL-plus-clock; and a file-write wall degrades gracefully, surfacing first at
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
both plaintext (5a) and TLS (5b) probes need it, so it stays on. Probe 2 (file write) is boot-confirmed on a local boot (FS behavior is pure kernel VFS,
identical local vs Nitro). Rows 3/4/6 are prior-observed or source-predicted and labelled as such —
hypotheses until an app boots into each wall. DB target + toolchain remain standing on the build host
for the follow-on probes.*
