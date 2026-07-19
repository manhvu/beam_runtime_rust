# Futex / boot-stall — consolidated history

**Status: OPEN.** A residual ~3% cold-boot stall persists on real hardware. This document is the
authoritative record of what is known, what was tried, what was ruled out, and *why* — so that
(a) nobody re-tests a dead hypothesis, (b) the verification work starts from a specification
rather than a blank page, and (c) the negative results survive.

**Supersedes** `MESSAGE_DELIVERY.md` and `BOOT_RELIABILITY.md`. Both contain valuable evidence but
their *conclusions are stale and in one case actively misleading* — see "Corrections" below.

---

## 1. Current reliability (authoritative numbers)

Success = reaches `phoenix_listening` **and** serves `curl /hello`.

| Harness | Result |
| --- | --- |
| c5.metal KVM, `-cpu host -smp 8`, 32 trials — pre-crypto `beam.smp` | **31/32** |
| c5.metal KVM, `-cpu host -smp 8`, 32 trials — crypto `beam.smp` | **31/32** |
| Nitro c5.large, cold-boot sweep (2 sweeps, 64 launches) | **62/64 (~97%)** reached `phoenix_listening` |
| Nitro c5.large from crypto AMI, 8 launches | **7/8** |
| QEMU/KVM Phoenix baseline (pre-watchdog-protocol-fix) | 53/64 (82.8%) |
| QEMU/KVM Phoenix (post-watchdog-protocol-fix) | 59/64 (92.2%) |
| QEMU/KVM, JIT | 60/64 (93.75%) |

The residual failure is a **cold-boot stall**: threads sit in `futex_wait` during ERTS SMP init.
No crash, no corruption. Retry always succeeds. Mitigated operationally by orchestration-layer
retry (standard cloud practice); two retries give ~99.97% effective.

**It is not a QEMU artifact.** It occurs on real Nitro (2/64) and on KVM (1/32).

---

## 2. Corrections to the superseded docs

These matter because a future reader — including a future us — would be misled.

**`MESSAGE_DELIVERY.md` claims "Boot reliability is now 64/64 = 100%."**
False. That figure was measured on the *gen_tcp echo* workload, not Phoenix; the Phoenix workload
subsequently measured 53/64 (82.8%) on the same tree. Current best is ~92–97%. The stall was never
eliminated.

**`MESSAGE_DELIVERY.md`'s B1 "fix" was itself the bug we later spent months chasing.**
B1 correctly identified that `watchdog_wake` set `state=Ready` but never queued the thread, so
rescued threads sat orphaned. Its fix: have the watchdog **push onto the CPU run queue (with a
`contains` check) and IPI the target — from the 1 Hz timer interrupt**. The doc even notes the
original author's dual-scheduling worry and dismisses it.

Months later an external review found exactly that: the watchdog mutating thread state and
touching run queues **from interrupt context without the futex bucket lock** races `futex_wait` and
`futex_wake` — double-queueing, stale-context rescue, corrupted lock handoff. Fixed properly by
making the watchdog only set an atomic `RESCUE_REQUESTED` flag, processed at safe scheduler points
under the proper locks. **83% → 92%.**

> **The watchdog added to rescue lost wakes was itself losing wakes.**
> This is the most instructive fact in the entire investigation. Note that a model checker finds
> this class of bug immediately; months of testing did not.

**`BOOT_RELIABILITY.md` lists unrestored RFLAGS as an open finding.** Fixed in `6704b69`. Its
dominant failure modes (`beam_load` opcode corruption, `#PF` in `erts_prepare_loading`) were the
data-corruption class, eliminated by FXSAVE/FXRSTOR + mmap zeroing + RFLAGS/DF preservation. Its
~81% figure predates all of that.

Its red-zone experiments *are* still valid and agree with later results — see H9.

---

## 3. Current design (as of this writing)

- **Bucket-hashed futex.** Waiters hashed by address into buckets, each with a spinlock.
- **Lock handoff.** `futex_wait` holds the bucket lock across `context_switch` and hands it off via
  `PENDING_UNLOCK_BUCKET`; the next thread to run on that CPU calls `release_pending_unlock()`.
  Intent: make check-and-sleep atomic w.r.t. `futex_wake`.
- **Pending wakes.** One-shot: a wake with no waiter records a pending entry; a subsequent
  `futex_wait` on that address consumes it and returns immediately. Covers wake-before-wait.
- **Watchdog.** Runs in the timer interrupt. Sets an atomic `RESCUE_REQUESTED[tid]` flag **only**.
  The scheduler processes rescues at safe points (idle loop, yield, `check_resched`) while holding
  the bucket lock + thread lock, re-checking state under lock. **It must never mutate thread state
  or run queues from interrupt context.**
- **Timer preemption.** The timer redirects user code through `sched_yield_trampoline`. `is_user` is
  `ip < 0x0F00_0000 || (ip >= 0x1A00_0000 && ip < 0xA000_0000)` — the second clause is essential:
  JIT/BeamAsm code lives in mmap space and must be preemptible (see §5, JIT fix).

### The ERTS side (what the futex must satisfy)

`erl_process.c` wake chain:
```
wake_scheduler(rq) → ssi_wake(ssi)
  flags = ssi_flags_set_wake(ssi)          // CAS clears SLEEPING|WAITING
  erts_sched_finish_poke(ssi, flags):
      POLL_SLEEPING → erts_check_io_interrupt(psi, 1)
      TSE_SLEEPING  → erts_tse_set(event)   ← futex_wake
      0             → no wake (not asleep)
```
Waiter: set `SLEEPING` → barriers → CAS add `TSE_SLEEPING` (abort if a wake already cleared flags)
→ `erts_tse_wait(event)` → `futex_wait`.

`ethr_event` states: `ON = 0`, `OFF = 1`, `OFF_WAITER = -1`.

---

## 4. Confirmed facts (the specification hand-off)

These are the inputs to any modelling/verification effort.

1. **The wake is lost in ERTS userspace, not in the kernel queue.** Instrumented ERTS:
   ```
   [etse-set]   addr=0x5a4d01d0 old=-1 new=0   ← waker sees OFF_WAITER → futex_wake ✓
   [etse-set]   addr=0x5a4d01d0 old=1  new=0   ← waker sees OFF → NO futex_wake ✗
   [etse-wt-in] addr=0x5a4d01d0 old=1  new=-1  ← waiter blocks forever
   ```
   `ethr_event_set` only calls `futex_wake` when the previous state was `OFF_WAITER`. A concurrent
   `ethr_event_reset` (`xchg → OFF`) between two sets erases `ON`, so the second set sees `OFF` and
   skips the wake.

2. **⚠ The central tension.** ERTS's `ethr_event` is correct against *Linux* futex semantics — it
   has run in production for years. Therefore **either** our futex is not a faithful refinement of
   Linux `FUTEX_WAIT`/`FUTEX_WAKE` (some window where our check-and-block isn't atomic, or our
   memory ordering differs), **or** our reading of the trace is incomplete. Resolving this is the
   single most valuable open question, and it is exactly what a refinement proof would settle.
   *Do not treat "ERTS has a race" as settled — it is the hypothesis, not the conclusion.*

3. **It is a genuine timing race, not a logic bug.** Rebuilding ERTS with a different compiler moves
   reliability dramatically with **identical source**:
   | ERTS build | TCG `-smp 1` |
   | --- | --- |
   | Original known-good | 4/4 |
   | Alpine 3.21 / **GCC 14.2** / musl 1.2.5 | **2/8** |
   | Alpine 3.19 / **GCC 13.2** / musl 1.2.4 (pinned) | **8/8** |
   Codegen perturbs scheduler timing. **The GCC 14 build is a reproduction amplifier — keep it.**
   A bug you can provoke is a bug you can validate a fix against.

4. **SMP-dependent.** Worsens under CPU oversubscription; near-absent at `-smp 1`.

5. **Occurs on real hardware.** Nitro 2/64, KVM 1/32. Not a QEMU scheduling artifact.

6. **Not data corruption.** That class (beam_load opcode errors, `#PF` in the loader) was fully
   eliminated by FXSAVE/FXRSTOR + mmap zeroing + RFLAGS/DF. The residual is pure liveness.

---

## 5. Real fixes that landed

| Fix | Effect |
| --- | --- |
| `FS_BASE` save/restore in `context_switch` (`a9c725d`) | OTP 27 could not boot at all without it — TLS aliasing between schedulers |
| `FS_BASE` in the idle-loop fast path | Correctness; no measurable reliability change |
| `FXSAVE`/`FXRSTOR` in context switch | Eliminated XMM-state corruption |
| `mmap` zeroing all allocations | Eliminated stale-pointer `#PF`/`#GP` (POSIX requires zero-fill) |
| `RFLAGS`/`DF` preservation across syscalls (`6704b69`) | Eliminated `rep movs/stos` corruption → `beam_load` failures |
| Watchdog B1: rescue now queues the thread | Rescued threads were orphaned outside every run queue. **But see §2 — the fix introduced the protocol violation below.** |
| **Watchdog protocol fix**: interrupt context sets an atomic flag only; rescue processed at safe points under bucket+thread locks | **83% → 92%** — the largest single reliability gain |
| `clone` writes TID pointers **before** spawning the child | Child could run before `CLONE_CHILD_SETTID` completed, breaking futex startup handshakes |
| Timer trampoline `is_user` includes the mmap range | **JIT root cause.** JIT code (≥ `0x1A000000`) was classified as kernel, so the timer only set `NEED_RESCHED` (checked at syscall exit) and never preempted JIT spin loops → scheduler deadlock. JIT went 0/8 → 16/16 |
| `newfstatat` honours the pathname (`S_IFDIR`/`S_IFREG`) | JIT's `code_server` init called `erl_prim_loader:list_dir("/otp/lib")`, got bare `error`, crashed |
| Honor `futex`/`epoll_wait` timeouts (parse timespec) | `receive after N` now fires |

---

## 6. The hypothesis ledger (what was tried and rejected)

| # | Hypothesis | Change | Result | Verdict |
| --- | --- | --- | --- | --- |
| H1 | Pending wake consumed by the **wrong address** (bucket-hash collision) | Per-address pending wakes instead of per-bucket | No durable improvement | **Rejected** |
| H2 | Pending wake **stolen by the wrong thread** waiting on the same address | Per-(addr,val) / counter-based pending wakes | No measurable change | **Rejected** |
| H3 | **Lock handoff × pending wake** interaction | Reordered handoff/consume | No durable improvement | **Rejected** |
| H4 | Value changed **between** pending-wake store and `futex_wait` | Re-check value on consume | No durable improvement | **Rejected** |
| H5 | **Multi-shot pending wakes** (counter per address) | Counter instead of one-shot flag | No measurable improvement; reverted | **Rejected** |
| H6 | Scheduler policy too naive → **CFS-style scheduler** | Replaced round-robin with CFS | **Regressed**; reverted | **Rejected** |
| H7 | **ERTS `ethr_event_set` patch** — wake on `OFF` as well as `OFF_WAITER` | One-line ERTS change | non-JIT 30/32 (~94%, CIs overlap baseline); **JIT 0/8 — no effect** | **Rejected/inconclusive.** Also violates the unmodified-ERTS goal. Note: this directly targets Fact §4.1 and *did not fix it* — a strong hint the story is incomplete |
| H8 | **Wake implies yield** (waker yields so the woken thread runs promptly) | Yield after `futex_wake` | No effect | **Rejected** |
| H9 | **Timer trampoline corrupts the x86-64 red zone** (writes below user `rsp`) | (a) push all 9 GPRs → **5/16**; (b) 128-byte red-zone gap → **9/16**; (c) remove the trampoline entirely → **49/64 (76.6%)** | All ≤ baseline | **Disproven.** Three independent tests agree. The red-zone write is a real ABI violation worth fixing on principle, but it is **not** the stall |
| H10 | Non-monotonic time / wrong `clock_gettime` | `fetch_max` ratchet on `LAST_TIME_NS` | Time is monotonic on both passing and failing runs | **Rejected** |
| H11 | CPIO data corruption (brk/mmap overwriting the VFS) | FNV-1a canary over the relocated cpio, re-checked at every `vfs::open` | Canary never changed across many runs incl. failures | **Rejected** |
| H12 | Insufficient register saving in the trampoline | Trace showed trampoline + `syscall_entry` together preserve **all nine** caller-saved GPRs | Hypothesis was simply wrong | **Rejected** |
| H13 | ERTS **spin counts / monotonic-time build patches** (`TIME_AND_SPINCOUNT`) — did patching ETHR spin counts to 1 and patching monotonic-time matter? | **De-patched entirely** (`7e4ec6e`): replaced the monotonic-time patch with proper TSC calibration + per-CPU offsets, and restored **default** `ETHR_SPIN_COUNT` — no build patches, no source mods | Runs unmodified OTP 27: `ERTS_CHECK_MONOTONIC_TIME` default with no "monotonic time stepped backwards" abort; **no deadlocks with default spin counts**, verified 8 CPUs + TCP end-to-end. The current reproducible `beam-build/` uses default spin counts (0 patches), and the §1 reliability numbers are measured on it. | **Resolved — defaults ship.** The old `BUILDING.md` spin-count/monotonic patches are superseded and were dropped. *One honest gap:* the isolated reliability **delta** of de-patching (patched vs default, all else equal) was never measured as a controlled experiment — but the disposition is grounded: defaults run unmodified OTP and the residual stall persists regardless, so spin counts are not the stall. |

### Live hypotheses — not yet tested (do these before another model-checking pass)

These are open. Each is a *specific* mechanism by which a wake could be lost or a rescue fail to
self-heal, and none has been instrumented. They are listed so they are tested deliberately, not
rediscovered.

| # | Hypothesis | Why it's plausible | How to test | Verdict |
| --- | --- | --- | --- | --- |
| H14 | **Lost / undelivered rescue IPI.** `send_ipi` is fire-and-forget — no delivery confirmation, no retry. If a rescue IPI is dropped (or the target AP is in a state where it can't take it), the rescue is a no-op and the thread stays parked. | The rescue is the safety net for a lost futex wake; if the net itself can silently drop, the ~3% residual is exactly what an occasionally-lost rescue would look like. **Key sub-question: do the APs have local-APIC timers armed?** If only the BSP gets timer ticks, an AP that misses its rescue IPI has *no* second event to re-trigger the rescue — the stall is then not self-healing on that CPU, which matches "retry the whole boot always works, but this boot never recovers." | Instrument `send_ipi` (count sends) vs an IPI-received counter on each target; confirm every AP has a local-APIC timer arming periodic ticks; add a delivery check / bounded retry and re-run the amplifier sweep. | **Open — untested** |
| H15 | **Idle-loop `cli`/`sti`/`hlt` discipline.** A wake (IPI or timer) that lands in the window between the idle loop's check-for-work and its `hlt` is lost until the next interrupt — the classic `sti; hlt` atomicity trap. | If the idle path does `cli` → check runqueue → (empty) → `sti` → `hlt` non-atomically, an IPI in the gap sets no pending state and `hlt` sleeps through it. On a CPU with no armed timer (see H14) that sleep is unbounded. | Audit the idle loop for the `sti; hlt` atomic pairing (interrupt must be enabled *by* `hlt`, not before it); check whether a wake arriving mid-check is preserved as pending. | **Open — untested** |
| H16 | **The second ERTS wake channel** (`POLL_SLEEPING` → `erts_check_io_interrupt` → self-pipe/epoll). The whole investigation has focused on the `TSE_SLEEPING` → `futex_wake` path (§3). The *other* branch of `erts_sched_finish_poke` wakes a poll-sleeping scheduler via the I/O poll set, and it has **never** been examined for lost wakeups. | §3 shows two wake targets; a scheduler blocked in `POLL_SLEEPING` is woken through `erts_check_io_interrupt` (self-pipe write / epoll), not the futex. If our `epoll`/self-pipe wake has the same lost-wake window the futex was suspected of, the bug could live here and every futex-side fix would miss it. | Instrument the `POLL_SLEEPING` branch: does `erts_check_io_interrupt` reliably wake a scheduler parked in our `epoll_wait`? Reproduce with the amplifier and check which sleep state the stalled scheduler is actually in (`TSE_SLEEPING` vs `POLL_SLEEPING`) — that single datum says which channel to chase. | **Open — untested** |

**Also ruled out as not-a-fix:** mapping more memory (pointers were already corrupt in registers,
not unmapped); bigger stacks (symptoms are too consistent for overflow).

---

## 7. What a verification effort should target

The residual bug is a **rare lost wake** in ~300 lines. It resisted 13+ hypotheses and moves with
compiler version. Testing has demonstrably failed to corner it; this is what model checking is for.

**Specification:** prove Tyn's futex is a faithful **refinement of Linux `FUTEX_WAIT`/`FUTEX_WAKE`**
semantics. That is the right spec precisely *because* ERTS is known-correct against Linux (Fact
§4.2) — so any divergence is our bug.

**Invariants to check first (TLA+ before Verus):**
1. **No lost wake.** A `futex_wake` issued after a waiter's value-check must wake it. (Check-and-block
   must be atomic w.r.t. wake.)
2. **No double-queue.** A thread is never on two run queues, nor twice on one.
3. **No stale-context resume.** A thread is never queued before `context_switch` has saved its context.
4. **Lock handoff.** `PENDING_UNLOCK_BUCKET` is always released before any thread re-enters that bucket.
5. **Watchdog non-interference.** Rescue can interleave anywhere and cannot violate 1–4. *(The
   historical bug lived exactly here — a good sanity check that the model has teeth.)*
6. **Memory ordering.** Our orderings vs Linux's futex guarantees.

Model the actors abstractly: waiter, waker, watchdog, scheduler/idle-loop, lock-handoff. Days, not
months — and it is the step most likely to *find the open bug*, not merely document it.

Only then Verus, on the futex proper. Other good Verus targets (self-contained, clear invariants,
places we've had real bugs): the fd table, the cpio parser, ENA ring index/phase-bit arithmetic,
the serial ring buffer. **Do not** attempt: inline asm, device I/O, crypto primitives.

---

## 8. Harnesses

**Standard sweep** (32 or 64 trials; success = `phoenix_listening` + `curl /hello`):
```bash
qemu-system-x86_64 -kernel target/x86_64-tyn/release/tyn-kernel \
  -m 2560M -machine q35 -cpu host -enable-kvm -smp 8 \
  -nographic -no-reboot -serial mon:stdio \
  -device virtio-net-pci,netdev=net0,disable-legacy=on,disable-modern=off \
  -netdev user,id=net0,hostfwd=tcp::5566-:8080
```

**Amplifier:** the Alpine 3.21 / GCC 14.2 ERTS build reproduces the stall at ~75% under TCG
`-smp 1` (2/8) versus 8/8 for the pinned GCC 13 build. **Preserve this build.**

**Caveats.** TCG `-smp 1` is a degenerate harness (single CPU, software emulation) — it disagrees
with real hardware and must not be used to judge reliability. Oversubscription (`-smp 8` on 2 vCPUs)
amplifies the stall and is *not* representative. Real-hardware sweeps (c5.metal KVM `-cpu host
-smp 8`, or Nitro launches) are the standard of evidence.

---

## 9. Standing lessons

- **The rescue mechanism was the bug.** Machinery added to paper over a race can introduce one.
- **A fix that "works" on an easier workload isn't a fix.** The 100%-on-gen_tcp claim masked an
  82.8%-on-Phoenix reality for months.
- **Toolchain-sensitive reliability means a race, not a logic error.** Treat codegen changes as
  experiments, and re-run the sweep after any ERTS rebuild.
- **Test the path the user takes.** The same failure mode recurred in crypto: binary-only KATs
  passed while iolist inputs — what Plug actually passes — failed.
