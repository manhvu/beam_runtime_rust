# Tyn verification — TLA+ models

Phase 1 of `directions/VERIFICATION_RESEARCH_PLAN.md`. Scope is the **narrow, Phase-0-confirmed**
one, not the wide pre-Phase-0 sketch: uniprocessor (the stall reproduces at `-smp 1`, so no IPI
layer), futex *trusted* (Phase 0 exonerated it), modelling the wait/wake/pending protocol, the
watchdog rescue, and — next — the init-phase valve/registration structure.

## Toolchain

- **TLC 2.19** (of 08 August 2024, rev 5a47802) — results here were produced with this exact
  version; TLC behavior can shift between releases, so pin it when reproducing. The jar is **not**
  committed (redistributed binary / its own license); fetch it into `verification/`:
  `curl -L -o tla2tools.jar https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar`
  (the v1.8.0 release ships TLC 2.19; `.../releases/latest/` also works but is not version-pinned).
- Java: openjdk 26 (`brew install openjdk` → `/opt/homebrew/opt/openjdk/bin/java`).
- Run: `java -cp tla2tools.jar tlc2.TLC -config <cfg> <spec>.tla`

## Models

### `WatchdogTeeth.tla` — the teeth-test (DONE ✓)

Before trusting the model on anything, it must catch a bug we **know** was real: the historical Tyn
watchdog bug, where the watchdog mutated thread state and run queues directly from **interrupt
context** (holding no locks), racing `futex_wake` and double-queuing a thread. The fix made the
watchdog only set a flag in interrupt context and do the real transition at a safe scheduler point
that takes the same locks as `futex_wake`.

Minimal faithful model: one blocked thread, `futex_wake` split into check→commit with an interrupt
point between (the window the bug lived in — the watchdog couldn't take the spinlock `futex_wake`
held, so it acted without it), and the watchdog as either the buggy interrupt-context mutator or the
fixed flag+safe-point drain. Property: `NoDoubleQueue` (no thread on the run queue twice).

| run | config | result |
| --- | --- | --- |
| `-config WatchdogTeeth_buggy.cfg` | `BuggyWatchdog = TRUE` | **NoDoubleQueue VIOLATED** — 4-state counterexample (FwCheck → *interrupt* WatchdogBuggy → FwCommit ⇒ `runq = <<1,1>>`), found in <1s |
| `-config WatchdogTeeth_fixed.cfg` | `BuggyWatchdog = FALSE` | **No error** — 9 distinct states, invariant holds, no deadlock |

The model catches, in a fraction of a second, a bug that survived months of testing — and confirms
the shipped fix removes it. This is the plan's gate for trusting the model, now passed; it is also a
standalone paper artifact (contribution: *this class of concurrency bug is trivially found by a model
checker*).

### `InitLiveness.tla` — the mechanism-pinning experiment (DONE — negative result)

A liveness model parameterized over `Sched ∈ {uni, smp}` × `Valve ∈ {block, spinyield}`: two ERTS
threads that each acquire a shared init lock, publish a readiness event (ethr_event, with the
`OFF→WAITER` cmpxchg-abort), then wait on the other's event. `uni` = cooperative uniprocessor (a
real-blocked thread is not runnable; a model of Tyn `-smp 1`); `smp` = free interleaving (a model of
Linux's parallelism). Property: `Terminates == <>AllDone`, under weak fairness per thread (we do
**not** assume the wake is fair — that would assume away the lost-wake question). Run with `-deadlock`
(TLC's structural deadlock check conflates *successful termination* — a terminal all-done state — with
a real stuck state; the temporal property and the `NotAllBlocked` invariant are the real signals).

| Sched | Valve | result |
| --- | --- | --- |
| uni | block | **No error** — terminates |
| uni | spinyield | **No error** — terminates |
| smp | block | **No error** — terminates |
| smp | spinyield | **No error** — terminates |

**Negative result, and it is a real one (not a failed run).** A faithful encoding of the init
protocol *as currently understood* is **live under all four combinations — including (uni, block),
the combination the stall supposedly needs.** The model was NOT tuned to reproduce the bug and was
not tweaked afterward to force it; whether the deadlock appeared was the experiment. It didn't.

What this establishes — stated at its true (modest) strength: the model is live **substantially by
construction**. Each thread publishes its readiness event (`Crit`) *before* it waits, so a partner
can never be parked on an unset event with its waker also parked — produce-before-wait leaves no
reachable cycle. The "live" verdict is therefore close to *tautological for the structure the model
contains*; TLC did not discover liveness through a deep interleaving argument, it confirmed a
structural property. So the honest reading is narrow: **the model confirms the understood pieces
compose safely, and confirms almost nothing about the pieces it does not contain.** That is still
worth having — it matches, mechanically, Phase 0's component-wise exoneration — but it is a bound,
not a mechanism.

The real deadlock lives in **structure this model does not capture**, i.e. structure not yet
empirically pinned. The honest lesson: **you cannot model your way to a mechanism you have not
empirically pinned** — the model can validate understood pieces (the teeth-test) and bound where the
bug is *not* (here), but it cannot conjure the unknown dependency graph. This is the paper's own
thesis recurring a third time: Phase 0 said *don't verify a target you picked by intuition*; this
says *don't model a structure you inferred rather than observed* — same failure mode, same
discipline, now at the modelling layer.

Concretely, the model abstracts away things the real init has and that could carry the cycle: more
than two threads (the trace has ~13, with a mutex victim behind which schedulers park), a dependency
graph that is not simple produce-then-wait pairing, and the possibility of a lock **held across** a
wait. Which of these carries the deadlock is an *empirical* question — the right next step is an
ERTS-side probe of the actual lock/wait dependency graph at the stall (who owns `0x…3964`, what each
parked thread is transitively waiting on), not more speculative modelling. Modelling a *hypothesized*
graph (e.g. lock-held-across-wait) is a legitimate follow-up **only if labelled as a hypothesis
test**, never as the confirmed mechanism.

## Next

- **Empirical (recommended):** an ERTS-side probe of the lock/wait dependency graph at a live stall —
  the datum the model needs and cannot invent. Pins the mechanism; then the model encodes the *pinned*
  graph and reproduces it (closing the report's one honest gap).
  - **Probe-design finding (verified, not assumed):** a frozen-memory walk alone is *insufficient*.
    The contended mutex in the trace (`0x…3964`, `flgs=0x2`) is an `ethr_mutex`; its struct
    (`ethr_mutex_base_`, `erts/include/internal/ethr_mutex.h`) stores `flgs` + a waiter queue `q`,
    but **no owner field**. So freezing at the stall yields *who waits* (via `q`) but not *who owns* —
    and the owner is the edge that matters (the parked thread whose release would unblock the waiter).
    Pinning the graph therefore needs ERTS-side **ownership instrumentation** (record, per lock, the
    owner tid; per thread, what it is blocked acquiring / on which event), then freeze at the stall
    (`stop` on the QEMU monitor) and read those fields in one atomic pass. A rebuild (Alpine-3.21,
    the amplifier) is required.
  - **⚠️ This crosses the perturbation line — everything to date did not.** Every read used so far is
    *non-perturbing*: QEMU-monitor extraction, in-memory rings dumped off the hot path, memory walks
    of existing structures. Adding fields to `erl_process`/`ethr_mutex` and rebuilding **instruments
    the runtime under test** — and this bug is timing-sensitive enough that GCC version alone moves it
    8/8 → 2/8. The added fields may shift timing so the stall changes character or vanishes.
    **Mandatory first check before any graph read is trusted:** A/B the instrumented build vs. the
    current amplifier — *does it still amplify with the ownership fields compiled in?*
  - **RESULT (2026-07-21) — the probe is perturbation-trapped; gate not passed.** Built the ownership
    instrumentation (a side table keyed by mutex-addr hash, owner's `gettid` recorded on the inline
    fast-path acquire/release — verified: `ethr_mutex` fast path is an inline `cmpxchg`, and note the
    kernel `gettid` returns `tid+1` vs the logs' `tid`, an off-by-one to correct for). It compiled
    clean in static-musl. The gate A/B (TCG `-smp 1`, always-block kernel, amplifier cpio, N=16 each):
    the plain baseline amplifier beam (md5 `d2d37d77`, byte-identical to the preserved amplifier)
    stalled **0/16**; the ownership beam stalled **0/16**; a positive control on the heavy
    `erl_process` ring beam stalled **4/6 (67%)** under the identical harness. So the stall rate is
    **dominated by build-specific timing perturbation** (~67× swing by instrumentation alone), not by
    the presence of the ownership fields per se. The bind: the stall is reliably observable only under
    instrumentation (the ring) heavy enough to doubt it is the *same* bug as the real ~3% stall, while
    the light ownership instrumentation that would be trustworthy does not reliably produce it to read.
    **A non-perturbing owner-capture would sidestep this** — e.g. reconstruct ownership from the mutex
    `q` waiter-queue plus a scheduler-state cross-reference at a *naturally-occurring* stall — and is
    the honest next design, not more instrumentation. Assets preserved on the build host
    (`disk_own.raw`, `disk_ref.raw`, `kernel_own`, `kernel_ref`, `beam.own.smp`, `Dockerfile.own`).
  - **Capture discipline:** freeze first, then walk in a single pass (a graph read across an evolving
    stall can show edges that never coexisted — the `-0x70`-offset trap again). Classify each chain's
    terminus into the three outcomes, do not assume a cycle: (a) genuine cycle; (b) a
    *runnable-but-never-satisfied* thread (rescue-livelock / scheduling, not a lock cycle — the
    `-smp 1` repro and the "quiescence, no work to poke" finding are both consistent with this);
    (c) a thread waiting on I/O or a timer (outside the model).
- **Modelling (optional, hypothesis-labelled):** extend `InitLiveness` with candidate structures
  (≥3 threads; lock-held-across-wait; cyclic dependency) to see which produce a *(uni, block)-only*
  deadlock — informative about plausibility, but not a substitute for the empirical datum.
- Remaining futex safety properties (lower priority — Phase 0 trusts the futex): lock-handoff
  exactness, no-stale-context-resume, no-lost-wake.
