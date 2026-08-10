# Paydown — accreted debt, named

Deferred cleanups and infra debt found across the arc. Kept in one named list so
it doesn't evaporate — several items are the **"small thing left undone that bites
later"** class this project keeps re-learning (the `.cargo/config.toml`
showstopper, the `tests/*` gitignore, the config-value-`"0"` crash). Open *defects*
live in `BUGS.md`; this is the debt-to-pay-down view, cross-referenced where they
overlap. Not ranked; each notes what it is, why it bites, and the fix if known.

## Config / deploy drift (the highest-bite class)

- **`-setcookie` baked into `main.rs`.** The Erlang dist cookie is hardcoded in the
  kernel argv scaffolding (uncommitted in-tree). Should move to **boot.config
  (per-image)** so it's not a kernel constant and doesn't leak/collide across
  deployments. *Fix:* thread it through `tyn_boot`'s env like the other runtime
  config. (Currently held out of git deliberately — do not commit the scaffolding
  as-is.)
- **DB password drift — `tynpass123`, out-of-band, not in git.** The Postgres
  password used in TLS/dist testing lives only in operator memory / host state, not
  in any tracked config. *Bite:* a fresh operator can't reproduce the DB path.
  *Fix:* record provenance + where it's set; decide tracked-secret vs
  documented-external.
- **IAM: build-host role can't revoke SG rules.** The build-host role lacks
  `ec2:RevokeSecurityGroupIngress`, so ≥2 in-VPC security-group rules opened during
  testing (**9100** dist, **6432** TLS/pgbouncer) are **un-revokable** by the tooling
  and linger. *Fix:* one IAM policy addition clears the whole class (grant the
  revoke action), then revoke the stale rules.

## Kernel hardening

- **Guard pages under stacks — the top hardening item.** Tyn identity-maps
  0–4 GiB, so a stack under/overflow **doesn't fault** — it silently corrupts
  adjacent mapped memory (the naive red-zone fix's `bad tag` crash was this). Guard
  pages under thread stacks would convert this whole class from silent corruption
  into a clean `#PF`. Reframed from nice-to-have to **the thing that would have made
  the red-zone class debuggable.** (`BUGS.md` → systemic hazard.)
- **4 GiB image/heap ceiling.** The identity map ends at exactly 4 GiB; large
  images/allocations near the top produce wild-pointer faults (BUG-4 class). Extend
  the map, or bound placement, if images grow.

## Dead code / cruft (proven, safe to remove)

- **`thread.rs` — the entire dead thread system.** `pub mod thread` with **no
  external callers** (`sys_clone` uses `sched::spawn`; `main.rs` runs `sched::init`).
  Its `CONTEXTS`, `KSTACK_NEXT`, `spawn`, `context_switch`, `yield` are all
  unreachable. Completeness-proven in `docs/STACK_ALLOCATOR_INVENTORY.md`. *Fix:*
  delete (removes a confusing second thread system + the `context_switch`-duplicate
  trap that misled the red-zone hunt for a session).
- **`syscall_stack_1` — dead 32 KiB static.** Declared (`syscall.rs:102-104`),
  never referenced. (Ironically useful: it's free space above `syscall_stack_0_top`
  that BUG-1's Path A can reuse for thread 0's preempt region — see the inventory.)
- **`percpu.rs::PerCpuData.kernel_stack` — unused field** (`[u8; 16384]` declared +
  zero-init'd, never read; TSS uses `ist_stack`, ring-0 never takes `rsp0`).
- **Arc scaffolding in-tree.** Diagnostic scaffolding built during the red-zone hunt
  (GPR fault dump, PREEMPT_DIV throttle) was reverted from `interrupts.rs`. Sweep
  for any remaining and loud-comment or remove.

## Latent correctness (cross-ref `BUGS.md`)

- **`arch_prctl(ARCH_SET_FS)` doesn't update `ctx.fs_base`.** Moot today (the switch
  reads live `rdmsr`), would bite if any path ever trusted the saved copy. `BUGS.md`.
- **`tyn_boot exit_group(127)` on a config value of `"0"` (BUG-2).** A literal `"0"`
  in boot.config kills boot — and it corrupted a *measurement* during the arc.
- **ERTS build can't link two static NIFs (BUG-3).** `--enable-static-nifs=a,b`
  mangles paths; worked around by one-module-many-functions. Tooling debt.

## Test / validation debt

- **Doc-status pass owed (Phase 1d).** The `docs/` + `directions/` corpus has grown
  large and some docs describe superseded states (wall_clock retraction, dist
  FAR→BUILDABLE, stunnel→pgbouncer). Label each current / superseded / paper-material
  so the corpus stops lying by ambiguity.
- **Standing suites not built yet (Phase 2).** Only the preemption probes are tracked;
  unit/resiliency/fuzz/soak layers are planned, not shipped
  (`directions/AUDIT_AND_TESTING_PLAN.md`). Networking claims must be measured on
  **Nitro, not QEMU** (QEMU has faked bottlenecks/truncation repeatedly).
