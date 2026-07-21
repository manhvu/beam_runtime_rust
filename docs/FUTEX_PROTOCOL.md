# Tyn futex — the intended protocol, stated precisely

Purpose: state the wait/wake/pending/rescue protocol as invariants, precisely enough to be a TLA+
spec (Phase 1). This is the modelling work the plan (`VERIFICATION_RESEARCH_PLAN.md` §Phase 1)
calls action #2. Where the prose cannot state an invariant cleanly, that is a finding, flagged
**[GAP]**.

**Scope: one CPU, N threads.** Justified by evidence, not convenience — the stall reproduces under
TCG `-smp 1` (`FUTEX_HISTORY.md` §8), where there are no APs, no IPIs, and no store buffers. So the
residual defect is a **uniprocessor logic error in the wait/wake/pending/rescue state machine**, and
the model needs none of the SMP layer (IPI delivery, `hlt` discipline, both wake channels) to
reproduce it. Those are deferred to a wider model as future work. Memory ordering drops out entirely
on a uniprocessor: every step below is a single atomic transition of shared state.

---

## 1. State

- **Threads** `T` (a fixed finite set). Each thread has:
  - `state ∈ {Running, Ready, Blocked, Dead}`. On one CPU, at most one `Running`; if none, the CPU
    runs the idle loop.
  - `wait_addr` — the futex word it is blocked on (`⊥` when not blocked).
  - `wait_val` — the value it expects that word to hold while it sleeps (the "still-parked" value).
  - `blocked_since`, `deadline` — timing fields for the watchdog.
- **Futex words** `W` — a fixed finite set of memory words (ethr_event fields, musl mutex words),
  each holding an integer `val(w)`. The kernel never writes these; *threads* (as ERTS/musl code) do.
- **Buckets** — `bucket(w)` maps each word to one bucket. Each bucket has:
  - a **lock** (`bmutex[b]`), and
  - a **pending set** `pend[b] ⊆ W`, capacity 8 (a set of addresses with a wake owed).
- **Run queue** `RQ` — a sequence of Ready threads (one CPU ⇒ one queue).
- **Handoff slot** `unlock_pending` — a bucket id or `⊥` (the lock handed across a context switch).
- **Rescue flags** `resc[T]` — booleans set by the watchdog, drained at safe points.

An **environment** (ERTS + musl, treated as an adversary/oracle we do not model internally) drives
`val(w)` writes and issues `futex_wait`/`futex_wake` calls. The refinement claim (§5) constrains
what the environment is allowed to assume.

---

## 2. Operations, as atomic-step sequences

### `futex_wait(self, w, v)`  — returns WOKEN | EAGAIN | TIMEDOUT
1. **acquire** `bmutex[bucket(w)]`.
2. if `w ∈ pend[b]`: remove it; **release**; return WOKEN.            *(consume wake-before-wait)*
3. read `c = val(w)`; if `c ≠ v`: **release**; return EAGAIN.          *(value already moved)*
4. set `self.state = Blocked`, `wait_addr = w`, `wait_val = v`, `blocked_since = now`.
5. select next runnable thread (or idle); set `unlock_pending = b`; **context switch away**.
   *(the bucket lock is NOT released here; it is carried across the switch — see INV-4)*
6. on resume: **release** `bmutex[b]` via the handoff (`unlock_pending`); return WOKEN/TIMEDOUT.

### `futex_wake(w, k)`  — wakes up to `k` waiters
1. **acquire** `bmutex[bucket(w)]`.
2. `woken = 0`; for each `T` with `state=Blocked ∧ wait_addr=w` (up to `k`): set `Ready`, enqueue,
   `wait_addr=⊥`, `woken++`.
3. if `woken = 0`: insert `w` into `pend[b]`.                          *(leave wake for a future wait)*
4. **release** `bmutex[b]`.

### `watchdog_tick()`  — interrupt context, sets flags only
For each `Blocked` thread with `wait_addr = w ≠ ⊥`, set `resc[T]` if any of:
- **value_changed**: `val(w) ≠ wait_val`   *(the value moved but no wake reached us)*
- **timed_out**: `deadline ≠ 0 ∧ now ≥ deadline`
- **stale**: `deadline = 0 ∧ now ≥ blocked_since + 5s`

### `process_rescues()`  — safe point; same lock order as `futex_wake`
For each `T` with `resc[T]`: under `bmutex[bucket(wait_addr)]`, if still `Blocked`, set `Ready`,
enqueue, `wait_addr=⊥`. (A spurious wake: no value is changed.)

---

## 3. Safety invariants (should already hold; TLC should confirm)

- **INV-2 — No double-queue.** No thread is on `RQ` more than once, and no thread is both `Running`
  and on `RQ`. *(futex_wake step 2 clears `wait_addr` and enqueues once; process_rescues re-checks
  `state=Blocked` under the lock and dedups the queue.)*
- **INV-3 — No stale-context resume.** A thread is never enqueued/run before `context_switch` has
  saved its context. *(Guaranteed by INV-4: the bucket lock spans wait step 4 → step 6, so a waker
  cannot mark the thread Ready and let it run on another path until the switch has completed and the
  lock is released.)*
- **INV-4 — Lock handoff is exact.** Every `bmutex[b]` acquired in `futex_wait` step 1 is released
  exactly once — by the next-scheduled thread via `unlock_pending` — and no thread acquires `bmutex[b]`
  while a handoff for `b` is outstanding. *(This is the mechanism that makes step 3–4 atomic w.r.t.
  `futex_wake`; if it can orphan or double-release, INV-1 breaks.)*
- **INV-5 — Watchdog non-interference.** `watchdog_tick` mutates nothing but `resc[T]`. All state
  transitions happen in `process_rescues` under the futex→thread→queue lock order. So a rescue can
  never violate INV-2/3/4. *(This invariant is the fix for the original interrupt-context watchdog
  bug — the historical teeth-test the model must still catch when the fix is reverted.)*

---

## 4. The liveness invariant — and the two places prose cannot close it

- **INV-1 — No lost wake (the property that matters).**
  > If, after thread `T` completes its value-check (`futex_wait` step 3, reading `c = v`) and commits
  > to blocking (step 4), some thread issues `futex_wake(w)`, then `T` is eventually made `Ready`.

  Mechanized intent: steps 3–4 and `futex_wake` step 2 are mutually atomic on `bmutex[b]` (INV-4), so
  a wake either *finds* `T` blocked (and wakes it) or *precedes* the block — and the precede case is
  covered by the pending set: `futex_wake` step 3 leaves `w ∈ pend[b]`, and `T`'s own step 2 consumes
  it. On a uniprocessor with INV-4 holding, there is *no* interleaving where a wake is both after the
  value-check and lost. **So if the model is faithful, INV-1 holds — and yet the boot stalls.** That
  contradiction is the whole investigation; it means one of the two assumptions below is false.

  **[GAP-A] — INV-1 assumes the waker's value-write is the value `T` is watching.** The real protocol
  has the waker do *two* things: (a) write `val(w)` to the "released" value, and (b) `futex_wake(w)`.
  `T` blocks on `wait_val =` the *un-released* value (ethr_event `OFF_WAITER = -1`; mutex `2`,
  locked-contended). INV-1 only bites once (b) is issued. If the waker **never runs**, neither (a) nor
  (b) happens, `val(w)` stays at `wait_val`, and `T` sleeps forever with `val(w) = wait_val` — the
  observed `cur == expect`. This is **not** a lost wake inside the futex; it is an *upstream* claim:
  the waker was itself blocked, so the wake condition never became true. Whether that is reachable is
  a property of the **scheduler-collective** dependency graph, which the model must include as the
  environment. *The prose cannot state INV-1 as a futex-only property because the antecedent ("a wake
  is issued") is exactly what fails.*

  **[GAP-B] — the pending set may drop a genuine wake.** The alternative to GAP-A: a `futex_wake(w)`
  *was* issued while `T` had committed to block but was not yet findable (a residual INV-4 window, or
  the wake targeting a `w` whose `pend[b]` slot was stolen/overflowed), so it inserted a pending that
  `T` never consumed (T is already past step 2), or found no slot (8-capacity overflow) and dropped
  it. Then INV-1 is violated *inside* code we own. The pending set is a set with capacity and
  one-shot consume; both are places a wake can be lost.

  **The `[rescue]`/`[wd-snap]` `pend(out= ever=)` probe decides A vs B:** for a stuck `w`,
  `ever = 0` ⇒ no `futex_wake(w)` ever left a pending ⇒ **GAP-A** (upstream; the waker never called
  it). `out = 1` ⇒ a pending sits unconsumed while `T` is stuck ⇒ **GAP-B** (a leak we own). This is
  the one datum the amplifier run is collecting.

- **INV-6 — the rescue is a spurious wake, and only a probabilistic escape.**
  > `process_rescues` makes a `Blocked` thread `Ready` with no value change. Correctness relies on the
  > environment tolerating spurious wakes: on resume `T` re-reads `val(w)`; if still `= wait_val` it
  > re-blocks. Therefore a rescue **restores runnability but never delivers the missing state
  > transition.** It can break a stall only if some other thread has meanwhile produced the awaited
  > state. Consequence (observed, and a property the model should exhibit): the rescue converts a hard
  > collective deadlock into a *probabilistic* one — most boots escape, a circular-wait interleaving
  > does not, and codegen timing shifts the probability. **A rescue is not a proof of liveness.**

---

## 5. The refinement claim (what Phase 1 actually checks)

Borrow Linux `FUTEX_WAIT`/`FUTEX_WAKE` as the spec (ERTS is production-correct against it, so any
divergence is our bug). The checkable question, sharpened by the finding:

> Does Tyn's futex ever fail to wake a waiter for which a `FUTEX_WAKE` **not accompanied by a value
> change** was issued? (The value-unchanged class: `OFF_WAITER→ON`, contended-mutex `2→0`, where the
> wake is the *only* signal and `value_changed` cannot backstop it.)

> **RESOLVED empirically (2026-07-19): GAP-A, not GAP-B.** The `pend(out= ever=)` probe on the
> amplifier shows every stuck address with **`ever=0`** — no `futex_wake` was ever issued to it — and
> lifetime `pw(ins=10 hit=2 miss=520)` (the pending path is barely used and leaks nothing). So the
> futex refines Linux faithfully *here*; the missing wake was never sent. See `FUTEX_HISTORY.md` §6,
> "The pending-wake trace." **Therefore a futex-only model would prove the wrong thing.** The model
> must include the two ERTS sleep-states and the waker's channel selection.

**Model outputs to look for:**
1. ~~If GAP-B is real…~~ **Ruled out empirically** — the pending set neither leaks nor overflows in
   the stall (`ins=10`, `out=0`). The INV-2..5 safety pass on the futex is still worth running (cheap,
   and it documents the primitive), but the futex is no longer the suspected defect.
2. **GAP-A is the truth.** The counterexample lives one layer up: model the sleeper publishing a
   sleep-state (`TSE_SLEEPING` ⇒ wake via futex; `POLL_SLEEPING` ⇒ wake via the I/O poll set) and the
   waker (`erts_sched_finish_poke`) *reading* that state to choose a channel. The property to violate:
   *a sleeper parked in TSE is woken through TSE* — a schedule where the waker reads a stale state and
   pokes the poll channel while the sleeper is TSE-parked reproduces `ever=0` + value-unchanged +
   permanent park. Needs the **one more Phase-0 datum** (instrument the `ssi` flags + the chosen
   branch) to confirm before the model is trusted, per the "get the datum, don't fix from it" rule.
3. **Teeth test (must pass first):** re-introduce the historical interrupt-context watchdog bug
   (mutate state + queues from `watchdog_tick`, no lock) and confirm TLC finds the INV-2/3/4
   violation. A model that misses a bug we know was real proves nothing.

---

## 6. Open question the prose surfaced

Stating INV-1 forced the split above: the property "no lost wake" is only meaningful *relative to the
value the waiter watches*, and the ERTS protocol makes that value one the waker only changes when it
runs. So "is the futex correct" is under-specified until we also model *when the waker runs* — i.e.
the futex cannot be verified in isolation from the scheduler-collective that decides whether the wake
condition is ever produced. That is the precise sense in which, per the plan, "people discover they
cannot state the invariant they thought they had."

---

## 7. The actual ERTS↔Tyn boundary (grounded in OTP 27.3.4.2 source)

`ever=0` puts the defect at the ERTS wake **decision**, above the futex. The relevant code — the
model's real target — is a **two-level** sleep protocol. Flags (`erl_process.h` 263–267):
`SLEEPING=1<<0`, `POLL_SLEEPING=1<<1`, `TSE_SLEEPING=1<<2`, `WAITING=1<<3`; `SLEEP_TYPE =
TSE_SLEEPING|POLL_SLEEPING`.

**Level 1 — `ssi->flags` handshake (pure userspace atomics).**
- Waiter (`scheduler_wait`, 3560–3607): `sched_spin_wait` sets `SLEEPING|WAITING`; then
  `sched_set_sleeptype(ssi, TSE_SLEEPING)` CAS-adds the sub-type; then **the abort check**
  `if (flgs & SLEEPING)` — only then does it call `erts_tse_twait(ssi->event)`. If a wake cleared the
  flags in between, `sched_set_sleeptype` returns without `SLEEPING` and the waiter **skips the wait**.
- Waker (`ssi_flags_set_wake`, 3674): CAS expecting `SLEEPING|WAITING`, resets to 0, returns old
  flags. `erts_sched_finish_poke` (1574) switches on `old & SLEEP_TYPE`: `POLL→check_io_interrupt`,
  `TSE→erts_tse_set(ssi->event)`, `both→both`, **`case 0: break` (no wake)**, default→abort.

**Level 2 — `ssi->event` (the ethr_event; this is where the kernel sees the stuck futex).**
`erts_tse_twait`/`erts_tse_set` run the ON/OFF/OFF_WAITER protocol on `ssi->event`'s futex word
(`0x5a600290`…). `erts_tse_set` is called *only* from `finish_poke`'s TSE branch.

**Why this narrows the probe.** Level 1's abort is pure atomics — identical on Tyn (uniprocessor), so
the classic `case 0` race is *self-correcting there*. The permanent park is at **Level 2**, and
`ever=0` means `erts_tse_set` was never called on the stuck events ⇒ `finish_poke` never took the TSE
branch for them. So the decisive question is precisely: **for each stuck event, was `finish_poke`
called, and did it take `TSE` or `case 0`?** — recorded against the event's futex address so it
matches the kernel's stuck `w`. The `-smp 1` model therefore needs: the waiter's two-level
registration, the abort check, `ssi_flags_set_wake`'s CAS, the three-way `finish_poke`, and the
event ON/OFF/OFF_WAITER layer. Everything else (IPI, `hlt`, ordering) stays cut.

**Open sub-question the source raises:** if Level 1's abort is sound on Tyn, how does a waiter reach
`erts_tse_twait` while its waker takes `case 0`? Candidate: the abort covers a wake that races the
*flags*, but not a wake intended for the *event* that is dropped between `sched_set_sleeptype`
succeeding and `erts_tse_twait` entering the event wait — a Level-1/Level-2 seam. The probe must
timestamp both levels to see the seam, not just the endpoint.
