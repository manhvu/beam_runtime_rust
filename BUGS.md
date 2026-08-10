# Tyn — tracked bugs

Open defects found during investigation, kept here so they don't seed the next
mystery. Record what was **measured**, not inferred. Newest first.

---

## SYSTEMIC HAZARD — the identity map hides every stack under/overflow

**Bigger than any single bug.** Tyn identity-maps 0–4 GiB, so a stack under/over-run
**does not fault** — it silently writes into adjacent mapped memory (e.g. the BEAM
heap) → downstream corruption (`size_object: bad tag`) instead of a clean `#PF`.
Every stack-bounds bug kernel-wide is therefore converted from a debuggable crash
into silent data corruption. The red-zone naive-fix crash (BUG-1 below) is the first
thing to expose it. **Implication:** guard pages under thread stacks would turn this
whole class into clean faults — reframed from "nice-to-have" to "the thing that
would have made this class debuggable." Feed into the hardening backlog.

---

## BUG-1 — preemption trampoline clobbers the interrupted thread's SysV red zone

**Severity:** high (silent wrong results — `:erlang.md5`/`binary.copy` return wrong
values under preemption; the "md5 large-binary flakiness" from the dist work).
**Status:** **root cause found and measured; correct fix pending** (Path A, below).

**Root cause:** `sched_yield_trampoline` (`src/interrupts.rs`) redirects a preempted
thread to `syscall(sched_yield)` by writing the saved RIP + rax/rcx/r11 to
`[user_rsp-8..-32]` — **inside the interrupted thread's 128-byte SysV red zone**
(handler does `new_rsp = user_rsp - 8`, no red-zone skip). BeamAsm/ERTS leaf hot
loops (md5/bincopy) that spill into their red zone get that stack memory clobbered
on preemption → wrong digest/copy. Transient (recovers on recompute) because it's
per-preemption timing, not a persistent memory clobber.

**Measured chain (each link a probe that could have refuted):**
- **dose-response:** amplifier mismatch scales with preemptive context-switch count
  — `PREEMPT_DIV` 1/4/16/64/0 → 42/7/7/1/**0**;
- **fully-off = 0** across 5/5 runs → **one** preemption-sensitive mechanism, no
  preemption-independent residual;
- **4 scalar probes all 0** — FS_BASE, GP(r12–r15), XMM(all xmm0–15), RFLAGS/DF, at
  full preemption + 16-worker dose. **NEGATIVE RESULT — the corruptor is NOT a
  register; it's memory.** (This closed the whole register hypothesis space and
  forced the memory pivot — a first-class finding.)
- **red-zone sentinel clobbered** — `redzone_probe` (`beam-build/nifs/fsbase_probe.c`)
  holds a sentinel in `[rsp-8..-128]` across a preempted spin; it comes back clobbered
  → corruptor named;
- **naive fix** (skip 128 B: `new_rsp = user_rsp-128-8`, `ret 128`) → amplifier
  **21→0** (0 across 8 runs), redzone_probe **clobbered→0** — mechanism AND symptom to
  zero, mechanism measured **before** the fix. **BUT** it introduced a measured
  **25% small-stack-underflow crash** (FIXED 2/8 vs UNFIXED 0/8): reserving 128 B
  below a small dirty/aux thread's rsp underflows into adjacent heap (see systemic
  hazard) → `bad tag`. Fix direction correct, **naive implementation reverted.**

**Correct fix (pending — Path A, `directions/REDZONE_FIX_RIGHT.md`):** move the saved
context off the user stack entirely — build an `iretq` frame on a per-thread
kernel/preempt area and resume via `iretq` (restores orig RIP + user_rsp + RFLAGS
atomically), with an **interrupts-disabled (IF=0) trampoline** so no nested
preemption (the IF=0 window — `check_resched`→`process_rescues`+`yield_current`→
`context_switch` — was verified bounded & non-blocking). Red zone never touched →
red-zone clobber AND small-stack underflow both structurally impossible. Deferred to
a post-audit session (needs the verified-complete kernel-stack-allocator inventory —
there are several across Tyn's two thread systems).

**Three earlier wrong turns (each caught by a refutable probe — recorded so they
don't recur):**
1. **XMM jump** — hypothesised XMM-clobber; refuted (xmm_probe, 0/95k, and md5's core
   is scalar). The narrow old probe (xmm0/xmm1) was a *near*-false-negative; the
   hardened all-xmm0–15 probe later also read 0.
2. **`context_switch` duplicate misread** — indicted `thread.rs:386` (GPRs-only) for
   omitting FS_BASE; the yield path actually uses `sched::context_switch`
   (`sched.rs:1184`), which DOES save/restore FS_BASE + fxsave. thread.rs:386 is a
   separate clone/init-path switch.
3. **FS_BASE promoted premise** — a directions file treated "FS_BASE fixed, amplifier
   30→0" as measured when it wasn't; the OFF/ON toggle proved FS_BASE **irrelevant to
   the amplifier** (fs_base preserved AND amplifier still corrupts).

Reproducers/probes: `tests/simd/` (amplifier + probe runners) +
`beam-build/nifs/{fsbase_probe,xmm_probe,canary}.c`.

## Unification (BUG-1 / BUG-4 / #72) — UNPROVEN, not merged

BUG-1, BUG-4 (boot `#PF`), and GP_HUNT #72 (tmpfs `#GP`) share a **plausible** cause
(red-zone clobber is a general memory corruptor → a beam pointer spilled to the red
zone and clobbered would fault wild). **Plausible ≠ measured.** They stay **separate**
until the Path-A fix's unification test runs: does the fix also kill the wild-pointer
faults? Gone → merge by measured shared cause; persist → separate. Do **NOT** merge on
the `0x100000000` 4-GiB-address coincidence (that coincidence already correctly *split*
BUG-1 from BUG-4 once).

## BUG-4 — boot `#PF` at `cr2=0x100000000` (beam.smp reads a wild ~4 GiB pointer)

**Severity:** high (crashes boot under QEMU/TCG). **Status:** symbolized; part of the
unproven unification above.

`demo-live.log:1668 #PF ip=0x989c81 cr2=0x100000000`. `0x989c81` is **beam.smp `.text`**
(not kernel — the original "kernel ip" read was the wrong binary), a heavily-unrolled
**byte-block hash** faulting on `movzbl 0x8(%rcx)` with `rcx≈0xFFFFFFF8` — a wild ~4 GiB
pointer walking off the top of the 4 GiB identity map. cr2 clusters at `4GiB+{0..0xb}`
across the corpus (not a fixed fingerprint — just the map wall). Not reproduced in the
current shipped tree (0/16 boots incl. amplifier); the reliable historical faults were
on experimental (FXSAVE/futex-valve) builds. Left open pending the BUG-1 unification
test.

## BUG-2 — `tyn_boot` crashes `exit_group(127)` on a config env value of `"0"`

**Severity:** medium. **Status:** open. A boot.config env var whose value is the string
`"0"` (e.g. `tyn-pack --env TYN_AMP_CHURN_KB=0`) makes the node `exit_group(127)` at
boot; non-"0" values boot fine. **Dangerous face:** it corrupted a *measurement* — it
blocked the churn=0 baseline, producing a false "churn-driven" reading of BUG-1 for two
reports before a `churn_type=none` run refuted it. A config bug that silently poisons a
test's control is worse than one that just crashes boot.

## BUG-3 — beam.smp build can't link two static NIFs at once

**Severity:** low (tooling). **Status:** open. `build-beam.sh --nif-modules "a b"`
produces `--enable-static-nifs=/build/nifs/a.a,/build/nifs/b.a` and the ERTS build
mangles the comma-list into one path (`ld: cannot find …a.a/build/nifs/b.a`). Single
NIF builds fine. Worked around by putting all probes in one module (`fsbase_probe.c`).

## Latent — `arch_prctl(ARCH_SET_FS)` doesn't update `ctx.fs_base`

**Severity:** low (currently moot). **Status:** filed. `sys_arch_prctl(ARCH_SET_FS)`
(`syscall.rs`) writes the FS_BASE MSR but never updates the saved `ctx.fs_base`. Moot
today because `sched::context_switch` (sched.rs:1184) reads the *live* fs_base via
`rdmsr`, not the saved copy — would bite if any path ever trusted `ctx.fs_base`. **Not
BUG-1.**
