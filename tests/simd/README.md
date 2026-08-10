# Preemption-corruption regression suite

Guards one kernel invariant: **a preemptive timer context switch preserves the
interrupted thread's full state — registers, flags, FS_BASE, XMM, *and* its stack
(the SysV red zone).** These probes are the hard-won guards from the red-zone
arc; each is written so it can return "not this" (a clean negative), and together
they name *which* state a preemption loses.

## The bug this suite exists for (BUG-1)

`src/interrupts.rs::sched_yield_trampoline` handles timer preemption of user
(JIT / `beam.smp`) code: the timer redirects RIP to a trampoline that does
`syscall(sched_yield)` → the kernel yield path.

**Root cause (measured):** the trampoline wrote its saved RIP + rax/rcx/r11 to
`[user_rsp-8..-32]` — **inside the interrupted thread's 128-byte red zone**.
BeamAsm/ERTS leaf hot-loops (md5/bincopy) that spill into their red zone get that
stack memory clobbered on preemption → a **wrong digest/copy** (the "md5
large-binary flakiness"). See `BUGS.md` (BUG-1) for the full measured chain and
the pending correct fix (Path A).

**How the corruptor was named — by elimination, not guessing:**
- dose-response: corruption scales with preemptive context-switch count
  (`PREEMPT_DIV` 1→0 gave 42→…→0), fully-off = 0 → one preemption-sensitive bug;
- the 4 scalar-register probes came back **0** → the lost state is **not a
  register, it's memory**;
- the red-zone probe's sentinel came back **clobbered** → the memory is the red
  zone.

## The probes, and what each detects (label matters — don't re-conflate)

Two categories. **Getting the category wrong is how the arc burned a cycle**
("md5 is scalar, so it can't be XMM" — true for md5's *core*, but its SSE `memcpy`
made XMM plausible; and the real answer was neither — it was the stack):

- **Memory-corruption detectors** (`beam-build/nifs/fsbase_probe.c::redzone_probe`,
  the **amplifier** `md5`/`bincopy` counters, `canary.c`): a non-zero means a
  *memory location* was corrupted across preemption. `redzone_probe` is the one
  that would have caught BUG-1 on day one — it holds a sentinel in `[rsp-8..-128]`
  across a preempted spin and checks it survived.
- **Register-corruption detectors** (`fsbase_probe.c::{probe,gp_probe,xmm_probe,
  rflags_probe}`, `xmm_probe.c`): each holds a known value in a specific
  register class (FS_BASE / GP r12–r15 / all xmm0–15 / RFLAGS-DF) across a
  **call-free** preempted spin and checks it survived. These proved **preserved**
  (all 0) — they are *negative guards*: they now stand watch against a regression
  that re-introduces register loss on the preemption path.

All are static NIFs in one module (`fsbase_probe.c`; single module to dodge BUG-3,
the two-NIF link bug) plus `xmm_probe.c`/`canary.c`, loaded by the `ampapp` app.
`TYN_PROBE=fsbase|gp|xmm|rflags|redzone` selects a probe; unset runs the md5
amplifier. Adequately **dose** every probe (16 workers, long spins) — an
under-dosed probe returns a false 0 (that lesson cost a report).

## Running

`drive_simd.sh` builds the zero-dep amplifier app, packs it onto the base OTP
cpio, boots under QEMU/TCG (slow TCG only *increases* preemption pressure — a
better amplifier), and asserts the mismatch **count** (behaviour-based, exact).
Valid on TCG and Nitro. See `BUGS.md` for the measured baselines.
