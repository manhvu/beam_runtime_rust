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

## Next (not yet built)

- **The init-phase liveness model** — the one that could *pin the mechanism* Phase 0 left unpinned:
  model threads that must make progress (not block) until an "init complete" point, a mutex whose
  owner may itself be parked, and the spin-yield valve; check whether *always-block* admits the
  circular-wait deadlock that *valve-on* avoids. If TLC produces that deadlock, the shape is
  confirmed; if not, the model is missing something real.
- Remaining futex safety properties: lock-handoff exactness, no-stale-context-resume, no-lost-wake.
