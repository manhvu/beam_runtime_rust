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

### Phase 0 code-read verdicts on H14–H16 (VERIFICATION_RESEARCH_PLAN.md)

Done as code reads (hours, no runs). Result: **the three lost-wake hypotheses are largely ruled
out** — a single naive lost wake self-heals, because several independent rescues sit on top of the
futex (100 Hz timer that pops the queue after every `hlt`; the watchdog every tick on
`value_changed`/`timed_out`/`stale`; epoll that yield-loops instead of parking). That is itself the
finding: the residual stall is not a naive lost wake, so the modelling should target the
*rescue-gap × ethr_event interleaving*, not the raw wake path.

**Framing (for the paper — resist calling this a "defensively-layered design").** These rescues are
not architecture; they **accreted empirically**, each added to narrow a failure window nobody could
yet state precisely, and each narrowed it without closing it. Three layers of rescue wrapped around
one futex is a **symptom that the protocol was never understood**, not a robustness feature. That is
the actual motivation for the verification work: the model is the attempt to finally *state* the
protocol instead of patching around it once more. (This supersedes the H14/H15/H16 "Open — untested"
rows above, which the code reads have now resolved to the verdicts below.)

- **H14 (lost IPI / AP without timer): mostly ruled out.** APs *do* arm local APIC timers
  (`apic::init_ap`, periodic 100 Hz). `CALIBRATED_TICKS` is set by the BSP in `init_bsp`
  (`main.rs`) **before** AP bringup, and x86-TSO makes the store visible to the AP — so the
  `if CALIBRATED_TICKS > 0` guard is satisfied. `send_ipi` waits on ICR delivery-status (bit 12),
  so loss isn't at the sender. *Residual smell:* the guard had **no `else` and no error** — an AP
  that ever reached `init_ap` before the store would silently run tickless. Latent, not active.
  **Fixed:** `init_ap` now takes an `else` branch that clears quiet mode and prints an
  `[apic] FATAL … CALIBRATED_TICKS=0` line, and the success log no longer claims `timer=100Hz`
  unconditionally — a tickless AP can no longer come up invisibly.
- **H15 (idle-loop `cli`/`sti`/`hlt`): a real check-then-sleep smell, but timer-rescued — a
  latency, not the permanent hang.** `cpu_idle_loop` does `sti; hlt` then pops the queue *after*
  `hlt` — it never re-checks the queue immediately before sleeping. A wake landing in the
  (drain → `hlt`) window whose IPI is consumed by an ISR before `hlt` leaves a runnable thread
  queued while the CPU sleeps. **But** the 100 Hz timer (`timer_handler` always EOIs at the top;
  idle `ip` is kernel so it just `timer_tick`s and `iret`s back to the post-`hlt` pop) wakes the
  CPU within ≤10 ms and the pop runs the thread. So H15 alone = ≤10 ms latency on an all-timers
  system, **not** a permanent hang. **Fixed:** `cpu_idle_loop` now disables interrupts, re-checks
  the run queue, and only sleeps via `enable_and_hlt` (atomic `sti; hlt`) when it is empty — closing
  the check-then-sleep window outright, so it cannot become a hang if the timer discipline ever
  changes. (A ≤10 ms latency today; a latent hang tomorrow.)
- **H16 (second wake channel / epoll): ruled out — it doesn't block.** `sys_epoll_wait` **yield-
  loops** (`net::poll()` each iteration; "we don't have eventfd-style blocking, just keep
  yielding"), so a scheduler in `epoll_wait` is never parked waiting for a poke it could miss.

- **The futex itself looks correct for Property 1.** In `futex_wait_until`, the value load and the
  `State::Blocked` mark are under the **same bucket lock**, and `pending_wake_consume` handles
  wake-before-wait. A wake cannot slip between check and block.

- **Where the permanent hang must live (refocused hypothesis).** The watchdog (`watchdog_wake`,
  every tick) rescues a Blocked thread on **`value_changed`** (`*futex_addr != futex_val` — the
  10 ms lost-wake backstop), `timed_out`, or **`stale` (Blocked > 5 s on an infinite wait)**. The
  *classic* lost wake — waker mutates the value to ON but skips `futex_wake` — is caught by
  `value_changed` within one tick. The gap: **if a lost wake leaves `*futex_addr == futex_val`
  (the ethr_event OFF_WAITER-stuck case), `value_changed` never fires and only the 5-second
  `stale` backstop rescues it.**

  **The data rules out "self-healing-but-slow."** An earlier draft here guessed the ~3% failures
  were 5 s stale-rescued boots that merely overran the sweep timeout. That does not survive the
  evidence: the Nitro sweeps waited **120 s** and the failures froze at `[net] initialized (ENA)`
  with **no `phoenix_listening` at all**. A stale rescue that *worked* would have unfrozen the boot
  ~5 s later, inside the window. It didn't. So the stale path is **not** quietly saving these boots,
  which leaves three materially different possibilities the modelling must distinguish:
  1. **Rescue fires, thread immediately re-stalls** — a 5 s/cycle livelock; looks permanent at any
     practical timeout.
  2. **Rescue fires but doesn't restore a runnable state** — rescued into a state that can't
     progress.
  3. **Rescue never fires** — its trigger condition (`stale`) isn't met, or the rescue delivery path
     itself has a bug.
  If (3), it is a rescue-delivery bug, *not* a refinement question, and dissolves §4.2 the way H14
  would have. If (1)/(2), the interleaving that produces the un-rescuable state is exactly the §4.2
  refinement question. *This is not settleable by more code reading* — it needs the amplifier plus
  instrumentation that logs, per stalled boot: does the stale rescue fire at all; how many times per
  tid (repeats ⇒ livelock, case 1); and does the rescued tid actually get CPU again (case 1 vs 2).
  That experiment is the immediate next action; only then the TLA+ model, with `value_changed`/
  `stale` as the rescue and the ethr_event ON/OFF/OFF_WAITER states modelled explicitly.

  **A further nail in H14.** The GCC-14 amplifier reproduces the stall under **TCG `-smp 1`** (§8) —
  a single CPU, *no APs and no inter-processor IPIs at all*. A hang that reproduces with zero IPIs
  cannot be, at root, a lost-IPI/AP-timer problem. Whatever the residual bug is, it lives in the
  uniprocessor futex/rescue logic, not the SMP wake-delivery path.

### Phase 0 experiment — the stall instrumented (GCC-14 amplifier, TCG `-smp 1`)

`watchdog_wake`/`process_rescues` were instrumented to answer the three cases directly (per-reason
flag tallies + a 1 Hz `[wd-snap]`; per-tid `RESCUE_COUNT`; a `[resched-in]` trace when a rescued tid
next gets CPU). Emitted from safe points / plain interrupt-context atomics, so it survives the hang.
Run against the amplifier disk. A representative stalled boot (`trial-01`, 130 s):

- **All 13 BEAM scheduler threads** (tids 2,3,6–16) stuck; each rescued **19–25 times** in 130 s.
- **Every** rescue is `reason=stale`; the `[wd-snap]` tally is **`stale=177 vchg=0 tout=0`** — the
  `value_changed` backstop **never fires once**.
- **Every** stuck thread has **`cur == expect`**: `0xffffffff` (ethr_event **OFF_WAITER**, = -1) for
  the scheduler waits, `0x2` (musl mutex **locked-contended**) for the lock waiters.
- **`[resched-in]` fires 278×** — the rescued threads *do* get CPU; they simply re-block.
- `phoenix_listening` is **never** reached.

**Verdict: case 1 (livelock), with the mechanism pinned.** The stale rescue fires (so not case 3)
and the rescued thread runs (so not "never scheduled"), yet the boot never advances: each thread
wakes, re-reads its ethr_event / mutex, finds it *still* in the waited-for state (no setter ran),
and re-parks. 13 schedulers cycle every 5 s with zero forward progress.

**But the rescue is a _probabilistic_ escape, not a dead one — and that is the real shape of the
bug.** The multi-trial sweep shows **PASS boots rescue too** (e.g. a boot that passed at 31 s logged
61 rescues). So a spurious wake is not useless: if, by the time it lands, some *other* thread has
made partial progress and set the awaited state, the woken thread proceeds and the logjam clears.
The STALL is the interleaving where the waiters form a **fully circular dependency** — every thread's
condition can only be satisfied by another thread that is itself parked — so no amount of re-rolling
spurious wakes ever finds a satisfiable moment. This is exactly why the watchdog safety net turned a
hard hang into a *rare* one (≈97% on Nitro) without ever closing it: it re-rolls the dice, it does
not deliver the missing state transition. Toolchain codegen (GCC-14) shifts the timing enough to
raise the probability of landing in the unrecoverable circular state.

**The fingerprint that unifies both victim classes: a lost wake in the _value-unchanged_ class.**
`value_changed` can only catch a lost wake where the value *moved* (unlock wrote 0 but skipped
`futex_wake`). The wakes that survive to hang the boot are exactly those where the value is
*supposed* to stay put and the `FUTEX_WAKE` is the **only** signal — ethr_event OFF_WAITER (waiting
for OFF_WAITER→ON) and a contended mutex (waiting for 2→0). For that class there is no value-based
backstop; the missing thing is the OFF→ON state transition that only the original (lost) waker could
have produced, and a spurious wake can only *substitute* for it when another thread has meanwhile
produced that state — hence the probabilistic escape above. The mutex waiters (`cur=0x2`) are
secondary — blocked on a lock still held by a primary ethr_event victim — so the root event is a
single lost, value-unchanged ethr_event wake that, in the unrecoverable interleaving, cascades into
a circular collective stall.

**This sharpened §4.2 into two rival branches** — a value-unchanged wake *lost inside the futex*
(`pending_wake` leak, our bug) vs *never issued at all* (divergence upstream at the wake decision) —
and a second instrumented run (the `pend(out= ever=)` probe on every stuck address) **decided it.**

### The pending-wake trace — GAP-A confirmed; the futex layer is exonerated

Second amplifier run, probe added: for each stuck address, `out` = a pending wake is outstanding
now, `ever` = a `futex_wake` ever left a pending for it; plus lifetime `pw(ins/hit/miss)`. A stalled
boot (`trial-06`, 130 s):

- **270 of ~300** stuck-OFF_WAITER rescues: `cur=0xffffffff expect=0xffffffff` **`pend(out=0
  ever=0)`** — across an array of per-scheduler ethr_event words (`0x5a600290`…`0x5a600550`, stride
  `0x40`). **No `futex_wake` was ever issued to any of them.**
- Lifetime **`pw(ins=10 hit=2 miss=520)`** — the pending mechanism is barely used all boot (10
  inserts total) and leaks nothing (`out=0` everywhere). It is not the bug.
- Mutex victims (`cur=0x2 ever=0`) are secondary — waiting on a lock still held by a parked scheduler.
- `tid=4` (`ever=1`, `reason=timeout`, `dl≠0`) is a **red herring**: the aux/timed thread cycling on
  1 s `ethr_event_twait` timeouts, doing no work and re-waiting — not stuck.
- Raw `nr=202` (the `futex` syscall) syscall-entry lines show each rescued thread **re-issuing
  `futex()` on the same address** immediately after every rescue — the livelock re-wait, confirmed at
  the syscall boundary.

**Verdict: this is GAP-A (`FUTEX_PROTOCOL.md` §4), not GAP-B.** The value stayed `OFF_WAITER` and no
wake was ever sent because **no thread ever executed `erts_tse_set` on these events** — the waker
never ran the wake. The futex/`pending_wake` layer faithfully lost nothing; there was nothing to
lose. **A futex-only refinement proof would have proved the futex correct and missed the bug** — the
exact Phase-0 trap the plan named. Avoided by evidence, not luck.

**Where the bug actually is (leading hypothesis, needs one more datum).** The schedulers parked in
the *TSE* channel (futex on their ethr_event, `OFF_WAITER`), yet were never `erts_tse_set`. The most
economical explanation consistent with `ever=0` **and** value-unchanged is a **sleep-state / wake-
channel mismatch**: the waker (`erts_sched_finish_poke`) read a stale `ssi` sleep-state and delivered
the wake through the *other* channel — `POLL_SLEEPING → erts_check_io_interrupt →` self-pipe/epoll —
while the sleeper was actually `TSE_SLEEPING` in the futex. That poke misses (the sleeper isn't in
epoll), the futex is never woken, and the event value is never touched. This re-opens **H16** in a
sharper form: not "a scheduler parked in epoll missed a poke" (epoll yield-loops, so that was ruled
out) but "**the waker chose the wrong channel** for a futex-parked sleeper." Confirming it needs one
more Phase-0 datum — instrument the sleeper's published `ssi` flags (`TSE_SLEEPING` vs
`POLL_SLEEPING`) and which branch `erts_sched_finish_poke` takes — **before** any modelling.

**Consequence for Phase 1 scope.** The `-smp 1` collapse still removes IPI delivery, the `hlt`
discipline, and memory ordering. It does **not** remove the two wake channels: the model must include
both sleep-states and the waker's channel selection, or it will re-commit the very error Phase 0 just
caught. The futex proper is now *out* of the suspected-defect set (though still worth an INV-2..5
safety pass); the wake-channel decision is *in*.

_(Raw logs: build host `~/work/p0/` (both runs). Amplifier disk `~/work/disk-instr.raw`; preserved
GCC-14 beam `~/kernel/beam-build/beam-gcc14-amplifier.smp` + `~/work/demo-rootfs.amplifier.cpio`.
Sweep pass/stall ratios in §8.)_

### The ERTS-side probe — where the wake is (not) issued

A second, ERTS-side probe (non-perturbing in-memory ring in `erl_process.c`, patched OTP 27.3.4.2,
built Alpine-3.21/GCC-14, extracted via the QEMU monitor at `nm` symbol `tyn_wake_trace @0x1016220`
— **zero kernel changes**) recorded, per `ssi`/event: the waiter transitions (`sched_spin_wait` →
`sched_set_sleeptype(TSE)` → `erts_tse_twait`, with observed `ssi->flags`) and `erts_sched_finish_poke`'s
three-way branch (`aux`: `0x4`=TSE, `0x2`=POLL, `0x0`=NONE/case-0). Extraction correlated to the
kernel's stuck futex addrs by `kernel_addr = ev − 0x70`. Findings from a persistent stall (ring
frozen at seq≈378 — schedulers stop calling `scheduler_wait` once parked; the kernel's stale rescues
re-wait *inside* `erts_tse_twait`, below the probe — so the ring holds the transition-into-stall):

- **The flags-layer abort is sound on Tyn.** Every TSE waiter goes `SPIN(0x9) → SETTYPE(0xd) →
  TWAIT(0xd)`: `SLEEPING` survives the `sched_set_sleeptype` CAS, so the classic `case-0` race
  self-corrects there exactly as the source predicted. The `case-0` pokes we *do* see (`flags=0x0`)
  are to already-awake schedulers — correct no-ops, not the bug.
- **10 of 12 stuck TSE schedulers are simply never poked on their final wait.** Poke count trails
  wait count by exactly one (`POKE_aux4 = TWAIT − 1`, last record `TWAIT fl=0xd`). They registered
  correctly and were woken in earlier cycles; the last wait gets **no poke because there is no work**.
  `pw(ins=0 hit=0)` confirms the futex did nothing this stall. This is a **work-quiescence**, not a
  lost wake.
- **The anomaly — a POLL poke to a TSE-parked thread — is the concrete edge.** The `maxblk` thread
  (`tid=3`, futex `0x290`) and one other (`0x590`) are **POLL-poked** (`aux=0x2 flags=0xb`) while the
  kernel sees them parked in the **TSE ethr_event futex** (`OFF_WAITER`). Those two facts cannot both
  be true of a correctly-functioning sleeper: a thread parked in its ethr_event futex should have
  **`TSE_SLEEPING`** published, so a poker reading its flags takes the TSE branch and calls
  `erts_tse_set`. Someone read **`POLL_SLEEPING` for a thread that was actually TSE-parked** — a
  **stale sleep-state read** (the wake-channel mismatch, appearing on the `maxblk` thread). It
  explains `ever=0` exactly: the poke went down the self-pipe/epoll path, nobody called
  `erts_tse_set`, the event stayed `OFF_WAITER`, the futex was never asked to do anything.
  *(These two threads have no waiter records, but that is **by construction** — the probe only
  instruments `scheduler_wait`'s TSE branch, so a thread that parked via another path or is a
  non-scheduler simply wouldn't appear. Absence is not evidence; the POLL poke is.)*

**Verdict — RESOLVED by a live-memory walk: work/progress quiescence, NOT a channel mismatch.** An
intermediate draft here proposed a "stale `POLL_SLEEPING` read on a TSE-parked thread" as the edge.
**That is retracted.** It rested on a `kernel_addr = ev − 0x70` correlation — and walking the actual
memory disproved that offset. The `ErtsSchedulerSleepInfo` struct is
`{ esdp@0; next@8; prev@0x10; flags@0x18; event@0x20; psi@0x28; aux_work@0x30 }`; reading `ssi->event`
and scanning the `erts_tse_t` for the `OFF_WAITER` (`0xffffffff`) word gives the **real** futex uaddr
= **`event + 0x10`** (proven: `ssi 0x…980` event `0x340` → `OFF_WAITER` at `0x350`; and 10 more, one
per kernel-stuck addr). The `−0x70` was **two interleaved stride-`0x40` arrays coinciding** — exactly
the coincidence-as-mapping failure this project keeps hitting. With the true offset, the "anomalous
POLL-poked stuck thread" evaporates: `ssi 0x…880` is the **poll thread** (`esdp=0`, `psi≠0`) doing
its normal job, its event **not** `OFF_WAITER`.

**The decisive scan (memory-only, offset-agnostic — for every ssi, read its own event's futex):**
```
--- TSE-PARKED (futex == OFF_WAITER) ---   [11 threads, all:]
ssi=0x…980..0x…c40  reg  flags=TSE(0xd)  event 0x340..0x5c0  futex@ (event+0x10) = OFF_WAITER
SUMMARY TSE-parked threads: TSE-flag(0xd)=11  POLL-flag(0xb)=0  other=0
```
**All 11 TSE-parked scheduler threads are regular schedulers correctly advertising `TSE_SLEEPING`
(`flags=0xd`). Zero POLL-mismatch.** They are parked in TSE, on their own events, awaiting a poke —
and simply never poked (`pw(ins=0 hit=0)`; the futex is faithful). This is a **scheduler-collective
work/progress quiescence**: the schedulers are *correctly* asleep with no work, and the wake that
would arrive when the next unit of boot work is produced never comes. Nothing is mis-flagged and no
wake is mis-routed or lost — there is genuinely no wake to issue.

_Residual honesty:_ the `maxblk` thread (`tid=3`, kernel `0x290`) was not among the 11 cleanly-mapped
`OFF_WAITER` schedulers at read time — its ssi read `flags=POLL/awake` with `futex≠OFF_WAITER`,
consistent with a timing skew between the ~20 s-old `wd-snap` and the live monitor read (it was
mid-transition), **not** a surviving mismatch. So "`tid=3` is the head of the chain" remains an
**inference**, not an observation; what is now *observed* is that the collective is a set of correctly
TSE-parked schedulers with no work.

**Consequence for the model.** Because it is quiescence and **not** "one thread published one channel
and parked on another," the small sleep-state/channel-selection model is **not** the right scope. The
real question is one level up: **why is no scheduler ever re-poked during ERTS init** — the
thread-progress registration phase. (Next section resolves *what causes it*.)

### RESOLVED — the stall IS the thread-progress registration deadlock; the spin-yield valve is disabled

`SPINYIELD_HYPOTHESIS.md` observed that Tyn's `futex_wait` has a spin-yield branch (`sched.rs`)
explicitly commented *"to avoid the thread-progress registration deadlock,"* gated on `FUTEX_BLOCKING`.
**Source read:** `FUTEX_BLOCKING` **defaults `true`** and is never set `false`; the only enabler is
`vfs::open`'s `if n == 99999` (a disable-by-absurd-constant, comment *"disabled — blocking futex
deadlocks gen_server calls"*). So **the spin-yield branch is dead code — real blocking is on from the
first instruction, and the registration deadlock that branch guarded is unguarded.** Both the
`new(false)→new(true)` default flip and the `n==99999` disable landed in **one commit, `a9c725d`
("OTP 27 boots: save FS_BASE across context_switch")** — which *simultaneously* fixed FS_BASE/TLS
corruption across `context_switch`, `mmap` MAP_FIXED zeroing, and more. So the valve was switched off
while TLS corruption was live — a bug fully capable of causing the "gen_server deadlock" that
motivated the disable, and fixed in that same commit. The valve may be off for a reason that no
longer exists.

**Decisive test (Step 2a, kernel-only, no ERTS rebuild): forced permanent spin-yield
(`FUTEX_BLOCKING = false`), amplifier, TCG `-smp 1`, 16 trials.** Classified by *fingerprint*, not
pass rate:

| build | FUTEX-STALL (OFF_WAITER + stale rescues) | of |
| --- | --- | --- |
| real-blocking (default) | **~15%** (3/20) | §8 |
| **permanent spin-yield** | **0** (0/32) — `p ≈ 0.85³² ≈ 0.005` vs the 15% baseline | this |

**Every spin-yield trial: `wd-snap=0 offwaiter=0`.** The `OFF_WAITER`/stale-rescue fingerprint
vanished entirely. The residual failures (10/16) are **all the separate, known, TCG-only `#PF`**
(`cr2 ≈ 0x100000000`, one past the 4 GiB identity map) that strikes *during Elixir module loading* —
i.e. **after** scheduler startup, so those boots passed the futex-stall point cleanly before hitting
an unrelated emulation limit. The 6 PASS boots reached `phoenix_listening` in ~10 s. So the `0/16` is
real, not masked by the `#PF`.

**Verdict: confirmed.** The residual boot stall is the **thread-progress registration deadlock**
exposed by real blocking during ERTS init — exactly what the (now dead) spin-yield branch existed to
prevent. Not a futex bug, not a wake-channel bug, not a scheduler quiescence needing a large model:
**a disabled safety valve.** This is still the paper's thesis (defect in composition, not components)
— the futex refines Linux, the flags handshake is sound, the poke is correctly withheld; the fault is
that a guard against a known init-phase deadlock was switched off.

**The real fix is NOT restoring the `n==80`-ish open-count heuristic** (an open-count proxy for "init
done" fails under codegen changes — the same class of guess that produced this). It is either (i) an
actual ERTS-init-complete condition to re-arm spin-yield only through registration, or (ii) better,
understanding *why real blocking during thread-progress registration deadlocks* and fixing that so no
valve is needed. Permanent spin-yield is a **diagnostic, not a fix** (burns CPU, defeats `HLT`, and —
per this sweep — its different timing trips the TCG `#PF` far more). The README's "hybrid futex"
description is also wrong and must be corrected (task tracked). _(Raw: build host `~/work/spin_sweep.txt`, `spin-*.log`; kernel `~/work/tyn-kernel-spinyield`, disk `~/work/disk-spin.raw`.)_

### ⚠️ REFUTED — the stall is NOT the registration barrier (live `intrnl` read)

A free monitor read of ERTS's own barrier state at a live futex-stall (symbol `intrnl @0x10eede0`
→ struct; `managed_count` at +0x14, `managed.no` at +0xc8, offsets verified by the `thr`/`callbacks`
pointer landmarks at +0xc0/+0xd0) returned **`managed_count == managed.no == 5`**: the
thread-progress **registration barrier is COMPLETE** at stall time. **So the registration-barrier
mechanism below is refuted** — the schedulers are stalled *after* registration, on a different
init-time blocking wait. What still stands: the *higher-level* result — spin-yield eliminates the
stall (0/32), so **real blocking during ERTS init is the cause** — and the disabled-valve /
workaround-hygiene finding. What is now reopened: *which* post-registration init wait deadlocks, and
why on Tyn but not Linux. **Consequence for the fix:** `managed_count==managed.no` is *also* the
wrong re-arm trigger (it is already true at stall time, so it would enable blocking *before* the
deadlock), just as open-count was — the real "init-complete" point is later than registration. The
next datum is an ERTS-side probe naming the actual post-registration blocking wait. _(The read was
worth it precisely because it refuted a mechanism before a fix was built on it.)_

### (a) Cheap edge-localization from logs (post-refutation) — narrowed, not pinned

With registration ruled out, the stall window is *post-registration*. Mapping every stuck tid to its
futex address from the kernel `[wait]`/`[rescue]`/syscall traces of a live stall:

- **tid=0 (main/boot thread) is NOT stuck** — its event `0x5a6001d0` is actively `[wake]`d throughout;
  the early OFF_WAITER waits were transient. The boot driver is fine.
- **Stuck set (stale-rescued):** **tid=2** on the **mutex `0x5a6c3964`/`0x5a6c38c4`** (`cur=0x2`,
  locked-contended, `ever=0` → owner never unlocks), plus schedulers **tid=3,6–16** on their
  ethr_events (`OFF_WAITER`). The schedulers are **secondary** — idle behind tid=2, whose post-lock
  work would generate theirs.
- **Cannot pin the edge cheaply:** a normal 0/1/2 mutex stores no owner, and identifying the lock /
  tid=2's ERTS role needs symbol/struct identification — an ERTS-side probe (rebuild). So (a)
  narrows it (tid=2 blocked on a specific mutex whose owner never releases; schedulers secondary) but
  does not name the edge.

### ✅ SHIPPED — conservative valve on the `serial_shell ready` marker (fix (i), honest trigger)

**Implementation:** `FUTEX_BLOCKING` defaults `false` (spin-yield through *all* of init); the kernel
arms real blocking when the boot eval prints **`serial_shell ready`** (`syscall.rs` write path —
already a watched marker for quiet-mode). `tyn_boot.erl` prints it *only after* `apply_config`
succeeds (the app started), so a stalled boot never reaches it and the entire deadlock window runs
under spin-yield. Dead open-count switch removed from `vfs.rs`.

**Why this trigger and not the others (all measured to fail):**
- open-count (`n==80`): fires mid-init → stall returns (5/16).
- `managed_count==managed.no`: already true at stall time → would arm pre-deadlock.
- first `listen(2)`: Tyn's serial shell listens on **9090 before the app** → armed mid-deadlock,
  stall returned (8/26, all `bfe=1`). And the app's HTTP listener (Bandit/8080) **doesn't traverse
  `sys_listen` at all** (verified: the only `sys_listen` call all boot is the shell's 9090) — so a
  listen hook cannot even see "the app is up." `serial_shell ready` is the boot harness's own
  app-is-up declaration and is beam/transport-independent.

**Validation (GCC-14 crypto amplifier, TCG `-smp 1`, N=32):**
`PASS=30, FUTEX-STALL=0, served-200=24, OTHER=2`. All three conditions met: **0/32 stalls**
(`offw=0` every trial); **`bfe=1` on all 30 PASS** (the valve genuinely armed — real spin-yield-then-
block, not permanent spin-yield); and the app **serves HTTP 200 under post-switch real blocking**
(the crypto beam serving requests with real `request_id`s — answering the open test-2 question:
blocking after boot does **not** break gen_server/serving). The 6 `serve=000` among PASS are curl
racing the just-lifted quiet-mode at the PASS instant (the serial shows the server logging real
responses), not serve failures; the 2 OTHER are TCG confounds (`exit_group`, slow-boot timeout), not
futex stalls. _(Raw: build host `~/work/fix_sweep.txt`, `fix-*.log`; kernel `~/work/tyn-kernel-fix2`,
disk `~/work/disk-fix.raw`.)_

**Re-validated STRIPPED (the shipped kernel, no Phase-0 instrumentation), N=32:** genuine
**FUTEX-STALL = 0/32** — the fingerprint stays gone with the diagnostic scaffolding removed, so the
0/32 was not an artifact of the instrumentation's timing (this is *the* thing that gets shipped, so
this is the number that counts). `PASS=22, OTHER=10`: the pass rate is lower than the instrumented
build's 30/32, but entirely because TCG **emulation** confounds rose (`Failed loading preloaded
module init (badfile)` → `exit_group(127)`, `#PF cr2≈4 GiB`, `#UD`, `DOUBLE FAULT`) — none futex-
related; stripping shifted boot timing enough to trip more of the amplifier's known TCG instability.
*(Classifier note: count OFF_WAITER blocking only within `[wd-snap]`/`[rescue]` lines; the pre-existing
`[wait]` debug log prints `cur=0xffffffff` before the spin-yield decision and is not evidence of a
block — a naive grep across all lines gives false positives.)*

**Caveat:** validated on TCG `-smp 1` (the amplifier regime). The reliability claim's gold standard
is a real-hardware run (c5.metal KVM amplifier, or Nitro) — deferred; this is the shippable fix, and
the metal spend is best used A/B-ing *this* build vs. the shipped default, not the diagnostic. Until
that runs, the 30/32 is the **same evidence class as the diagnostic** (TCG) — good, not gold — and
the historical baselines it improves on (~97% Nitro, ~94% KVM) were measured on real hardware, so
the comparison is not yet apples-to-apples. Do not let the reliability claim propagate to a
real-hardware assertion before a metal A/B.

**Two side-findings worth keeping:**
- **Bandit's HTTP listener does not go through `sys_listen`.** Instrumenting `sys_listen` showed the
  *only* call all boot is Tyn's serial shell on 9090; the app reaches `phoenix_listening` / "started
  apps on port 8080" with **zero** `listen(2)` syscalls. So Bandit/ThousandIsland acquires its
  listening socket by a path other than the POSIX `listen` syscall (worth knowing next time anyone
  reasons about the socket path) — and it is *why* a listen-hook trigger structurally could not see
  "the app is up."
- **The shipped trigger is a boot-harness print, not an ERTS property** — `tyn_boot.erl`'s
  `serial_shell ready`. Correctness of the futex mode now couples to that string. Mitigations in
  place: loud ⚠️ comments at both the arm site (`syscall.rs`) and the flag (`sched.rs`), and a
  `watchdog_wake` elapsed-time fallback (120 s after first spin-yield) so a boot path that never
  prints the marker arms anyway instead of spinning forever. This is the workaround-hygiene lesson
  applied to our own fix: leave a loud trail and a backstop, unlike the valve that was silently
  disabled.

### DECISION (deliberate, not by momentum): bank + ship conservative valve + TLA+ target

Per the standing guidance to decide consciously after (a): **stop the probe cycle here.**
- **Confirmed/durable:** real blocking during init → stall; spin-yield → 0/32; valve disabled;
  workaround-hygiene archaeology (paper-grade); four components exonerated (futex, flags handshake,
  poke decision, registration barrier).
- **Reliability fix (does not need the mechanism):** re-arm blocking on a **deliberately conservative**
  trigger that is unambiguously past boot — the app listener up, or a generous elapsed-time bound —
  documented as conservative, not principled (semantic triggers open-count and `managed_count` are
  both empirically dead). Converts ~3% → 0.
- **Mechanism = research:** the exact post-registration wait on `0x5a6c3964` and why Tyn's scheduling
  admits a circular wait Linux's does not — now a small, confirmed TLA+ scope, not an intuition.

### Mechanism (source read of `erl_thr_progress.c`, OTP 27.3.4.2) — REFUTED, see above

`erts_thr_progress_register_managed_thread` (lines 636–651) is an **all-managed-threads barrier**:
each thread registers, increments `managed_count`, then loops on `callbacks->wait` until
`managed_count == managed.no`; the **last** registrant instead runs `wakeup_managed(id)` for every
other thread — the single wake that releases the barrier. Therefore: **if any managed thread blocks
(real `futex_wait`) anywhere in its early init before reaching registration, `managed_count` never
reaches `managed.no`, the wake-all branch never executes, and every already-registered thread parks
forever in `callbacks->wait` with no wake ever issued.** This is precisely the Phase-0 fingerprint —
`ever=0` (no `futex_wake`/`erts_tse_set` on the stuck events), schedulers correctly TSE-parked
(`flags=0xd`) and never poked, genuine quiescence. The "quiescence" was **schedulers waiting at the
registration barrier for a thread that never arrived** (the mutex victim `0x…3964`, `cur=0x2`, is a
plausible pre-registration blocker). This is a *structural* deadlock, which is why spin-yield fixes
it (no thread truly blocks pre-registration → the barrier completes) rather than merely by shifting
timing. It reframes the valve: **spin-yield-until-registration-complete is the correct enforcement of
ERTS's invariant — a managed thread must make forward progress, not block, until registration is
done.** So fix (i) (re-arm the valve with a real registration-complete trigger) is principled;
(ii) "no valve at all" would fight the barrier's design.

### The finding — a workaround-hygiene lesson (write this into the paper)

The generalizable result here is not the deadlock; it is the **workaround that outlived its cause**:

- Commit **`a9c725d`** (James, 2026-05-05, *"OTP 27 boots: save FS_BASE across context_switch"*)
  fixed **FS_BASE/TLS corruption across `context_switch`** — "threads reading each other's TLS."
- **In the same commit**, it flipped `FUTEX_BLOCKING` default `false→true` and disabled the
  spin-yield switch (`if n == 99999`, comment *"disabled — blocking futex deadlocks gen_server
  calls"*).
- The "gen_server deadlock" the disable was reacting to was observed **while TLS corruption was
  live** — a bug fully capable of producing it (corrupted per-thread wait/wake bookkeeping) and
  **fixed in that very commit**.
- The workaround was **never revisited**. It went on to cause a *different*, harder bug — the ~3%
  cold-boot stall — that took **months and four scope-pivots** to trace back here.

Workaround for symptom X installed; root cause of X fixed in the same commit; workaround left in
place; workaround later causes a distinct, subtler failure. A clean, citable lesson about workaround
hygiene in AI-assisted development — arguably a better story than the deadlock itself.

**Test 2 (valve re-enable, `default false` + switch at `n==80`), 16 trials: PASS=4 (served=0),
FUTEX-STALL=5, OTHER=7.** The futex-stall fingerprint **returned** (5/16, all with `bfe=1` = switch
fired, `offw≈290`). So re-arming the valve with an **open-count trigger fails**: BEAM loads its
bootstrap modules (>80 opens) *before* it spawns schedulers and runs registration, so `n==80` flips
to blocking *during* registration and the barrier deadlocks again. This is empirical confirmation
that **an open-count proxy for "init done" is the wrong signal** (not a threshold to tune —
module-opens don't track registration). The gen_server-deadlock question is **left unresolved**: the
reintroduced futex-stall masks any separate gen_server issue, and the 4 PASS boots' `serve=000` is
ambiguous (harness/port timing vs a real hang). **Consequence:** fix (i) needs a *real*
registration-complete signal (e.g. ERTS signalling Tyn when `managed_count==managed.no`), not a
proxy; this tilts toward **fix (ii)** — pin and fix the actual circular wait so no valve is needed —
or a fix (i) built on an honest signal.

### Completeness — why doesn't Linux deadlock? (source read of the barrier + spawn)

The barrier is **lost-wake-safe by construction**: `register_managed_thread` calls `prepare_wait`
(arms the event) *before* the `managed_count` increment, so a waker that sees the increment always
finds the event armed. So a wake is never *lost*; the wake-all simply never *fires* when a thread
never registers. And Tyn's **spawn path is correctly ordered** — `home_cpu` set and both TID pointers
written *before* `push_back` makes the child runnable (`sched.rs:519–545`; the old "child runs ahead
of its setup" clone window is closed) — so candidate (b)-in-spawn is ruled out. The remaining shape
is a **circular wait**: the stuck set always includes a contended mutex (`0x…3964`, `cur=0x2`)
alongside the barrier events — thread B blocks on that lock pre-registration; its owner C has already
registered and is parked at the barrier waiting for B; B never registers → barrier never completes →
`ever=0`. On Linux, true parallelism lets C release the lock before parking; on Tyn (amplified by
`-smp 1` cooperative scheduling, but present cross-CPU too since Nitro is also ~3%) the closing
interleaving is reachable. **Not yet pinned from source alone** — the deciding datum is *which*
managed thread never registers and *what* it blocks on (an ERTS-side probe). This tilts toward fix
(i) (spin-yield through registration breaks the cycle regardless of its exact edges), while leaving
fix (ii) open pending that datum.

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

**Phase-0 instrumented sweep (2026-07-19):** amplifier disk (`~/work/disk-instr.raw` = instrumented
kernel + demo cpio) under TCG `-smp 1`, 14 trials → **1 STALL / 13 PASS**. The one stall is fully
diagnostic (see §6, "Phase 0 experiment"). Two honest caveats: (i) the stall rate here (~7%) is
below the bare amplifier's ~25%, consistent with the rescue-path serial logging adding latency that
mildly perturbs this timing-sensitive race — it did **not** mask it, but a lower observed rate is
expected under instrumentation; (ii) PASS boots also rescue (10–89×), so "PASS" here means *escaped
the livelock*, not *never entered it*. Per-trial logs: build host `~/work/p0/`.

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
