# Paydown — accreted debt, named

Deferred cleanups and infra debt found across the arc. Kept in one named list so
it doesn't evaporate — several items are the **"small thing left undone that bites
later"** class this project keeps re-learning (the `.cargo/config.toml`
showstopper, the `tests/*` gitignore, the config-value-`"0"` crash). Open *defects*
live in `BUGS.md`; this is the debt-to-pay-down view, cross-referenced where they
overlap. Not ranked; each notes what it is, why it bites, and the fix if known.

## Config / deploy drift (the highest-bite class)

- **★ PRIORITY — the build host `~/kernel` is NOT a git clone.** It's a mutable,
  hand-synced source tree with no `.git`. This **silently breaks the
  artifact-matches-git guarantee that all validation rests on**: a binary that
  passes acceptance was built from *whatever bytes were in that tree at build time*,
  with nothing tying them to a commit. This session it held only because Path A's two
  files hashed **byte-identical** to the commit when checked by hand (SHA-256 match) —
  a manual check that happened to pass, not a structural guarantee, and one nobody
  will remember to run every time. **Third recurrence of this class** — kin to the
  `.cargo/config.toml` showstopper and the `tests/*` gitignore (an untracked thing
  quietly severing source↔build correspondence). Do not wave it off again.
  **Blocks BUG-5's bisect directly:** a bisect *is* `git checkout <commit>` → build →
  test, per step; you cannot do that on a tree with no history, and building "the
  Aug-8 kernel" or walking commits forward is impossible without it. *Fix (do before
  BUG-5):* make `~/kernel` a real clone of `github-personal:tyn-os/kernel` (or a fresh
  clone beside it that `deploy-ami.sh` builds from), verify `git status` clean +
  `HEAD` == the commit under test, and have the deploy log record the built `HEAD` SHA
  so every artifact is traceable to a commit. Non-source build inputs that live only
  on the host (embedded `beam.smp`, `clock2.cpio`) need the same provenance discipline.
- **Nitro serve regressed since Aug-8 (BUG-5).** The stock kernel + `clock2.cpio`
  served on Nitro Aug-8 but the same pipeline NO-SERVEs now — measured, stock kernel,
  so **not** Path A. Blocks *all* real-hardware validation (incl. BUG-1's Nitro
  residual). *Fix:* bisect the Aug-8→now commits (deploy the Aug-8 kernel as a
  positive control first), or diff SG/`build-disk.sh`/`deploy-ami.sh` vs Aug-8.
  Hampered by Tyn serial not reaching EC2 console (HTTP :8080 is the only signal).
  `BUGS.md` → BUG-5.
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
