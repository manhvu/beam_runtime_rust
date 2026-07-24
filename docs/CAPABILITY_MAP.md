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
| 5a | **Ecto + Postgres, plaintext TCP** | yes | **DB: YES — raw Postgrex *and* standard eager Ecto Repo** | two walls, both packaging — **RESOLVED** | stale base-image artifacts (missing `elixir.app`; stale `tyn_boot.beam`) | none kernel-side; base-image packaging fixes | **CONFIRMED — Postgrex on Nitro; eager Ecto local→same VPC DB** |
| 2 | Phoenix + file write | yes | no (write fails) | `open(O_CREAT)`/write to a file path | VFS is read-only cpio; `sys_write` has no file case, `sys_open` no create path | writable filesystem (tmpfs) | source-predicted |
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
  config from `runtime.exs` — connects and queries: `EAGER_ECTO_RESULT: OK rows=[[42]]` against the
  real VPC Postgres. (Boot: local QEMU on the in-VPC build host, NAT'd to the *same* VPC Postgres the
  Nitro probe used — the DB, wire protocol, and full Ecto/DBConnection/Postgrex stack are real; only
  the L2 path differs from the pivotal ENA row, which is separately Nitro-confirmed.) *No missing
  primitive: this was packaging, cheap, and it unblocks the standard ORM path — the change that turns
  "raw Postgrex works" into "a normal Phoenix+Ecto app runs."*
- **Wall B — native resolver on connect.** postgrex's default connect path spawns `inet_gethost`
  (ERTS's native DNS port program), which Tyn cannot exec (`ebadf`) → the node **crashes**
  (`exit_group(1)`). Even a literal-IP hostname triggered it until the inet lookup method was forced
  off `native`: `:inet_db.set_lookup([:file, :dns])` before connecting makes it use the pure-Erlang
  resolver and the connection succeeds. `tyn_boot`'s `configure_dns/0` already runs before
  `start_apps`, so a fresh `tyn_boot.beam` (the Wall A #2 fix) also settles this at boot. *Missing
  primitive: either subprocess/exec (to run `inet_gethost`) or a default inet config that never
  selects `native` — the latter is already in `tyn_boot`.*

## Synthesis — what to build next

**Because plaintext Postgrex works *and* the standard eager Ecto Repo works once the base image is
re-packaged, DB connectivity is *not* the blocker and Ecto is *not* the blocker.** Re-ranked by what
they unblock:

1. **Land the Wall A packaging fixes in the base image (cheap, done-in-principle).** Ship Elixir's
   `.app` files (`elixir`/`logger`/`eex`/`mix`/`iex`) in the base cpio, and rebuild `tyn_boot.beam`
   from current source as part of the image build (`BUILDING_ERTS.md` packs Elixir `.beam` but not
   `.app`, and nothing recompiles `tyn_boot.erl`). This is what turns "raw Postgrex works" into "a
   normal Phoenix+Ecto app runs" — validated locally against the real VPC DB (`[[42]]`).
2. **TLS-to-DB (the managed-Postgres unlock).** Not yet tested, but `--without-ssl` makes it the
   expected next wall: managed Postgres (RDS/Supabase) requires TLS, and the wall-clock-at-1970 issue
   would also fail cert dates. Turns "plaintext only" into "works with a managed DB." **Now the
   highest-value *unknown*.**
3. **Writable tmpfs** — breadth (any disk touch), independent of the DB story. → Probe B.

The one-sentence version: **stateful DB-backed apps are reachable on Tyn today — raw Postgrex over
plaintext TCP is Nitro-confirmed, and the *standard eager Ecto Repo* works too once two stale
base-image artifacts (`elixir.app`, `tyn_boot.beam`) are re-packaged (local-confirmed against the real
VPC DB) — so the next real unknowns are TLS-to-DB for managed databases and a writable FS, not the
database plumbing or the ORM.**

---

*Probe 5a is boot-backed: raw Postgrex over ENA is Nitro-confirmed (artifacts above); the eager-Ecto
resolution is confirmed on a local QEMU boot NAT'd to the *same* VPC Postgres (a fair proxy for the
packaging/config fix, which is network-agnostic — the ENA path is Nitro-confirmed separately). The
clean Nitro re-run of the full eager-Ecto path is the natural next confirmation but was not burned for
a packaging fix. Wall A fix artifacts: base cpio + Elixir `.app` files (`elixir`/`logger`/`eex`/`mix`/
`iex`) + recompiled `tyn_boot.beam` from `src/erl/tyn_boot.erl`; app = minimal `ecto_sql`+`postgrex`
release with `MyApp.Repo` in the tree and DB config in `runtime.exs`. Rows 2/3/4/6 are source-predicted
or prior-observed and labelled as such — hypotheses until an app boots into each wall. DB target +
toolchain remain standing on the build host for the follow-on probes.*
