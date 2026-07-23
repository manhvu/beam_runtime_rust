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
| 5a | **Ecto + Postgres, plaintext TCP** | yes | **DB: YES (raw Postgrex)** | see below (two walls) | — | — (works) / see walls | **CONFIRMED — Nitro** |
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

- **Wall A — Ecto's Repo won't start.** `Ecto.Repo.Supervisor.repo_init/3` calls
  `Code.ensure_loaded?/1`, which fails: *"function Code.ensure_loaded?/1 is undefined (module Code is
  not available)."* This is **not** a missing file — `Elixir.Code.beam` is present at the cpio root,
  the same place as `Elixir.Enum.beam`/`Elixir.GenServer.beam` that the Phoenix demo loads fine. So
  `Code` specifically fails to load where peer modules succeed (a code-server / load-time gap, not a
  path gap). **Ecto is how most Elixir apps talk to a DB**, so "Postgrex works but Ecto's Repo won't
  start" is the wall that actually gates the common stateful-app pattern. The probe reached the DB
  only by driving `Postgrex` directly, bypassing Ecto. *Missing primitive: whatever makes Elixir
  `Code` (and the compile/code-load surface Ecto touches) unusable at runtime.*
- **Wall B — native resolver on connect.** postgrex's default connect path spawns `inet_gethost`
  (ERTS's native DNS port program), which Tyn cannot exec (`ebadf`) → the node **crashes**
  (`exit_group(1)`). Even a literal-IP hostname triggered it until the inet lookup method was forced
  off `native`: `:inet_db.set_lookup([:file, :dns])` before connecting makes it use the pure-Erlang
  resolver and the connection succeeds. *Missing primitive: either subprocess/exec (to run
  `inet_gethost`) or a default inet config that never selects `native`.* A deployable fix is to set
  the lookup method at boot (tyn_boot already configures the resolver; it should also drop `native`
  from `lookup`).

## Synthesis — what to build next

**Because plaintext Postgrex works, DB connectivity is *not* the blocker; the blockers are one layer
up.** Ranked by what they unblock:

1. **The Ecto/`Code` gap (highest value).** Fixing whatever makes Elixir `Code` unloadable unblocks
   the *standard* ORM path — i.e. nearly every real Phoenix+Ecto stateful app, which currently dies at
   Repo-init. This is the single change that turns "raw Postgrex works" into "a normal Phoenix+Ecto
   app runs."
2. **TLS-to-DB (the managed-Postgres unlock).** Not yet tested, but `--without-ssl` makes it the
   expected next wall: managed Postgres (RDS/Supabase) requires TLS, and the wall-clock-at-1970 issue
   would also fail cert dates. Turns "plaintext only" into "works with a managed DB."
3. **The `inet_gethost`/native-resolver default** — cheap: drop `native` from the boot-time inet
   `lookup`, so apps don't crash resolving a host. (Low effort, removes a sharp edge Probe 5a hit.)
4. **Writable tmpfs** — breadth (any disk touch), independent of the DB story.

The one-sentence version: **stateful DB-backed apps are reachable on Tyn today via raw Postgrex over
plaintext TCP (Nitro-confirmed), so the next investments are not the database plumbing but the Ecto
`Code`-load gap that blocks the standard ORM path and TLS-to-DB for managed databases — with a cheap
boot-time inet-`lookup` fix to stop the native-resolver crash along the way.**

---

*Probe 5a is boot-backed (Nitro, artifacts above). Rows 2/3/4/6 are source-predicted or
prior-observed and labelled as such — they are hypotheses until an app boots into each wall. DB
target + toolchain remain standing on the build host for the follow-on probes.*
