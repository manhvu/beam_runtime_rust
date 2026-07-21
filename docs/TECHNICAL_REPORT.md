# The bug was in the composition, not the components

*A technical report on a rare cold-boot stall in Tyn, and what chasing it across five scope-pivots
says about picking verification targets. Draft — arXiv skeleton. Written while the reasoning is
fresh; the bug catalogue and the measurement narrative below are the perishable part.*

---

## 0. One-paragraph version

Tyn is a bare-metal x86-64 microkernel (~8,000 lines of Rust) that hosts an *unmodified* BEAM VM
(Erlang/OTP 27, BeamAsm JIT). It had a rare (~3%) cold-boot stall: BEAM scheduler threads park in
their futex-backed sleep events and are never woken. We set out to verify Tyn's futex against Linux's
`FUTEX_WAIT`/`FUTEX_WAKE` semantics, on the theory that the futex was the defect. **It was not.** A
disciplined "find the bug before modelling" phase exonerated the futex — and then, in sequence, four
more primitives: the sleep-state handshake, the scheduler poke decision, the thread-progress
registration barrier, and (a false lead) a wake-channel mismatch. The actual cause was a **disabled
safety valve**: a spin-yield path that let `futex_wait` avoid blocking during runtime init existed in
the code but had been switched off — in the very commit that fixed the bug it was originally added to
work around. To be precise about what is and isn't solved: **the valve's absence is the cause and is
fixed; the exact circular wait that real blocking exposes during init is still unpinned** — cause
identified, mechanism open, mitigated (§7), which is also the setup for the modelling work in §10. The
lesson that generalizes is not the deadlock; it is that **choosing a verification target by intuition
proves the wrong thing**, demonstrated five times over rather than asserted.

---

## 1. System and context

- **Tyn**: Rust `no_std` kernel, custom `x86_64-tyn` target, ~50 syscalls, 16 MB static heap. Boots
  an unmodified static-musl BeamAsm `beam.smp` from a cpio, on QEMU/KVM and real AWS Nitro.
- **Why unmodified ERTS matters**: prior art that reimplemented the VM (LING) failed on exactly that
  reimplementation. Running the stock emulator means the OS surface — not the runtime — is the
  variable under test, which is what makes the following a statement about the *boundary* between an
  OS and a managed runtime.
- **The futex is load-bearing**: ERTS's thread scheduler sleeps on `ethr_event`s, which on Linux are
  thin wrappers over `FUTEX_WAIT`/`FUTEX_WAKE`. Tyn implements those two syscalls. If they diverge
  from Linux, ERTS — which is correct against Linux by years of production evidence — breaks.

## 2. The bug

- **Symptom**: on ~3% of cold boots the node never reaches `phoenix_listening`; serial freezes with
  the BEAM schedulers blocked. A boot *retry* always succeeds, so it read as flaky, not
  deterministic.
- **Toolchain sensitivity — the tell**: identical ERTS source, different compiler → different stall
  rate. Under QEMU-TCG `-smp 1`, Alpine 3.19 / GCC 13.2 boots **8/8** healthy while Alpine 3.21 /
  GCC 14.2 stalls **6 of 8** (2/8 pass). A defect whose frequency moves with codegen is a **race**,
  not a logic error in a single path. We preserved the GCC-14 build as a reproduction *amplifier* —
  the single most valuable diagnostic asset in the project.
- **Three rate regimes — do not conflate them.** (i) *Production / real hardware:* ~3% on Nitro (the
  symptom we care about). (ii) *Bare amplifier* (GCC-14, TCG `-smp 1`, no kernel instrumentation):
  ~75% stall (2/8) — the amplifier's job is to make a 3% race frequent enough to study. (iii)
  *Instrumented amplifier* (the same build with the Phase-0 diagnostic ring and its serial logging):
  ~15% (3/20). The instrumentation itself perturbs a timing-sensitive race — its serial-path latency
  suppresses the rate roughly five-fold. This is not a footnote: it dictates that any A/B measured
  *within* an instrumented build must use the instrumented rate (~15%) as its null, not the bare 75%
  (§4), and it is *why* the shipped fix was finally validated on a **stripped** kernel (§6).
- **Harness honesty up front**: TCG `-smp 1` is a *degenerate* harness (one CPU, software emulation)
  that disagrees with real hardware. Every reliability number here from TCG is labelled as such. The
  real-hardware baselines (~97% Nitro, ~94% c5.metal KVM) are the gold standard; the TCG amplifier is
  a magnifying glass, not a scale.

## 3. The investigation: five pivots, five sound components

We ran Phase 0 — *find the bug before building any model* — precisely because verifying the wrong
component is a wasted month and a result reviewers would attack. Each pivot below ruled a component
*sound*, by evidence, and moved the target. That convergence is itself the finding.

The recurring method — **read the artifact before building on an inference** — earned its place by
catching several confident-but-wrong reads (§5).

1. **The futex faithfully refines Linux.** A non-perturbing in-kernel trace (an in-memory ring dumped
   off the hot path) recorded, per stuck address, whether a `futex_wake` was ever issued. Verdict:
   **`ever = 0`** on every stuck event — *no wake was ever issued*. Nothing was lost inside the
   futex, because nothing was sent. Corollary: a futex-only refinement proof would have proved the
   futex correct and missed the bug entirely — the Phase-0 trap, avoided by evidence rather than
   luck.
2. **The ERTS sleep-state (`ssi->flags`) handshake is correct on Tyn.** An ERTS-side probe (a
   non-perturbing ring compiled into `erl_process.c`, extracted via the QEMU monitor at a symbol
   resolved with `nm` — zero kernel changes) showed every scheduler registering its sleep type
   cleanly: `SLEEPING` survives the `sched_set_sleeptype` CAS, so the classic check-then-sleep race
   self-corrects there, exactly as the source predicts.
3. **The scheduler poke is correctly withheld.** The stuck schedulers registered their sleep, were
   woken in earlier cycles, and simply received no poke on their final wait — *because there was no
   work to signal*. Quiescence, not a lost wake.
4. **The thread-progress registration barrier is complete.** A live read of ERTS's own barrier state
   (`intrnl->managed_count` vs `managed.no`, offsets computed from the struct and confirmed by
   pointer landmarks) returned **`5 == 5`**: all managed threads registered. This *refuted our own
   leading mechanism* (a registration-barrier deadlock) on a free read — killing the hypothesis
   before a fix was built on it.
5. **The "wake-channel mismatch" was a measurement artifact.** A promising lead — a POLL-poke to a
   TSE-parked thread — rested on an `event → futex` address offset of `−0x70` that held across ten
   waiters. Walking the actual memory disproved it: the true offset is `+0x10`; `−0x70` was **two
   interleaved stride-`0x40` arrays coinciding**. The "anomalous" thread was the poll thread doing
   its normal job. Retracted.

Earlier, three lost-wake hypotheses (a lost rescue IPI, an idle-loop `sti;hlt` window, a second
epoll wake channel) were ruled out by code reading — the kernel has *layered* rescues, so a single
lost wake self-heals. Combined with 13+ hypotheses rejected in prior sessions, the negative-results
ledger is large, and it is the useful artifact: almost never published, genuinely reusable, and its
size is AI-specific — a written ledger became load-bearing because dead hypotheses were otherwise
relitigated across context boundaries.

## 4. Root cause: a disabled safety valve, and the archaeology

The stall reproduces under TCG `-smp 1` — one CPU, no inter-processor interrupts, no store buffers —
so it is a **uniprocessor logic error**, not a memory-ordering or SMP-delivery bug. That narrowed it
to the wait/wake state machine during runtime init.

Reading the code found a spin-yield path in `futex_wait`: during ERTS init it is supposed to *yield*
rather than *block*, with a comment stating it exists "to avoid the thread-progress registration
deadlock." It is gated on a flag, `FUTEX_BLOCKING`. **That flag defaults to `true` and is never set
`false`; its only enabler is guarded by `if n == 99999`** — a disable-by-absurd-constant, commented
"disabled — blocking futex deadlocks gen_server calls." So the spin-yield branch is dead code, real
blocking is on from the first instruction, and the init-time deadlock the branch existed to prevent
is unguarded.

**The decisive test** (kernel-only, no ERTS rebuild): force *permanent* spin-yield — a **diagnostic
build**, never shipped, that just proves causation — and re-run the amplifier. Result: the
`OFF_WAITER` / stale-rescue fingerprint **vanished, 0/32** — against the same instrumented build's
~15% null (§2, regime iii), `p ≈ 0.85³² ≈ 0.005` (and far stronger against the bare 75%; we quote the
conservative same-build number). Blocking during init is the cause; spin-yield eliminates it. *(This
0/32 is the diagnostic; the shipped valve's own 0/32 is a distinct measurement on a different build,
§6 — do not merge them.)*

**Then the archaeology, which is the better story.** `git blame` on the disabling line: both the
default flip (`false → true`) and the `n == 99999` disable landed in **one commit** — the commit
titled *"OTP 27 boots: save FS_BASE across context_switch,"* which fixed **FS_BASE/TLS corruption
across `context_switch`** (schedulers reading each other's thread-local storage). The "gen_server
deadlock" that motivated disabling the valve was observed *while that TLS corruption was live* — a
bug fully capable of producing it, and **fixed in the same commit**. The workaround was never
revisited. It sat for months, then went on to cause a *distinct*, subtler bug — this ~3% stall — that
took five scope-pivots to trace back.

> A workaround was installed for symptom X. The root cause of X was fixed in the same commit. The
> workaround was never removed, and it later caused a different bug. — This is a clean, generalizable
> lesson about workaround hygiene, and it is the paper's center of gravity.

## 5. How we fooled ourselves measuring

Each item is a real confound that produced a confident, temporarily-persuasive wrong belief:

- **Coincidence as mapping.** The `−0x70` offset (§3.5) *looked* structural because it was constant
  across ten samples; it was two interleaved arrays. Clean disproof: a real `event → futex` offset
  must be `≥ 0`. Noticing that before modelling is the discipline working.
- **Grep scope as truth.** In the final validation, a post-hoc classifier grepped `cur=0xffffffff`
  across *all* serial lines and flagged a "genuine stall." Reading the log showed those matches were
  on a pre-existing `[wait]` debug line printed *before* the spin-yield decision; the boot had
  actually died on a TCG `badfile` fault. The correctly-scoped classifier (matching only within
  `[wd-snap]`/`[rescue]` lines) said zero. Had we trusted the grep, we'd have chased a phantom into
  the paper.
- **A plausible mechanism the data contradicted.** An early write-up guessed the ~3% failures were
  "self-healing-but-slow" (a 5-second rescue overrunning the sweep timeout). The Nitro sweeps waited
  120 s and the failures never recovered — the guess did not survive the data it was supposed to
  explain.
- **Instrumentation that hides the bug.** Because the defect is codegen-timing-sensitive, we assumed
  probes could perturb it away, and deliberately built *non-perturbing* in-memory traces rather than
  prints. This assumption is why the final fix was validated on the **stripped** kernel, not the
  instrumented one that happened to score well (§6).
- (From earlier phases, same failure class:) SLIRP as a ~350× throughput confound; a host bridge
  silently dropping SYNs; a "resource leak" that was an eval timeout; a concurrency ceiling that was
  a single buffer constant; a status-code assertion passing over a truncated body; a "correct"
  34 KB/s transfer that was window-limited.

## 6. The fix, and four triggers that failed

The reliability fix does not require pinning the exact deadlock. "Spin-yield through init, block
after" is proven; the only question is *when* to switch. That question turned out to be the whole
difficulty, and it recapitulates the paper's theme — a proxy for "init is done" is a guess that fails
under the same timing pressure as the bug:

| trigger | result (stall count) | why it failed |
| --- | --- | --- |
| module open-count (`n==80`) | **5/16 stalled** | BEAM loads >80 modules *before* it spawns schedulers; fires mid-init |
| `managed_count == managed.no` | arms pre-deadlock | already true at stall time (§3.4), so it would enable blocking before the deadlock window |
| first `listen(2)` | **8/26 stalled** | Tyn's serial shell listens on :9090 *before* the app; and the app's HTTP listener **never traverses `sys_listen`** (an odd, useful finding on its own) |
| **`serial_shell ready` marker** | **0/32 stalled** | the boot harness's own "the app is up" print, emitted only after init completes; a stall never reaches it |

The shipped trigger is a boot-harness *print*, not a property of ERTS — so correctness now couples to
that string. Applying the workaround-hygiene lesson to our own fix: loud comments at both ends of the
coupling, and a watchdog elapsed-time **fallback** (arm blocking anyway 120 s after first spin-yield)
so no boot path can spin forever if the marker never arrives. Unlike the valve we found disabled,
this one leaves a trail and a backstop.

**Shipped-artifact validation.** The kernel that ships (commit `1cac02f`, verified byte-identical to
a fresh build of the committed source, md5 `0856b67b`) was swept on the GCC-14 amplifier, TCG
`-smp 1`, N=32: **genuine FUTEX-STALL 0/32**; 22/32 PASS; 10/32 OTHER, all TCG emulation confounds
(`badfile`/`exit_group`, `#PF` at the 4 GiB identity-map edge, `#UD`, `#DF`), none futex-related. Of
the 22 PASS, the valve armed on every one and 21 served HTTP 200; the single non-serving PASS is a
harness artifact — `curl` raced the just-lifted post-boot quiet-mode at the instant of PASS, and that
boot's serial shows the server logging real request responses, so the server was up. The lower pass
rate vs. the instrumented build (30/32) is entirely those TCG confounds rising as stripping shifted
boot timing — the *fingerprint*, which is what we measure, is zero in both. This 0/32 is a **distinct
measurement** from §4's diagnostic 0/32: different build (shipped valve vs. permanent spin-yield),
same harness and N.

## 7. Honest limits

- **Harness.** 0/32 is on TCG `-smp 1`, a harness we have repeatedly called degenerate. It is the
  same evidence *class* as the diagnostic runs — good, not gold. The reliability claim must not
  propagate to a real-hardware assertion before a bare-metal-KVM-amplifier (or Nitro) A/B of this
  build vs. the shipped default. That A/B is the correct next spend precisely because `1cac02f` is the
  thing that ships. **Attempted and deferred (hardware):** we launched a `c5.metal` for exactly this
  A/B (two disks differing only in the valve, ready to sweep) and drew a **Cascade Lake 8275CL** —
  the CPU this project's own hardware matrix documents as having a QEMU/KVM virtio-DMA-coherence bug.
  Confirmed empirically on the box: early boot is clean but the serial stream corrupts (BEAM bytecode
  leaks in at ~21 KB), so no clean fingerprint measurement was possible. The one documented-*working*
  CPU (Broadwell `i3.metal`) is no longer offered in the region; the remaining metal types are newer
  CPUs whose behavior with this kernel is untested. So the metal A/B is **deferred on hardware
  availability, not skipped** — the falsifier below stands, stated but not yet run.
- **Mechanism.** *Cause identified, mechanism unpinned, mitigated.* We know real blocking during init
  causes it and spin-yield removes it; we have **not** pinned the exact circular wait (the shape: a
  scheduler blocks on a post-registration init lock whose owner is itself parked). Why the
  interleaving is reachable on Tyn but not Linux — Tyn's cooperative `-smp 1` scheduling admits
  orderings real parallelism does not — is the open research question, and now a *small, confirmed*
  target for a model.
- **n = 1.** Single project, single human director, no control condition. The observations about
  AI-assisted development below are reported, not generalized; the author is a participant in the
  thing described, not a neutral observer, and the report says so.
- **What would falsify this.** The story predicts that the `OFF_WAITER` fingerprint is absent from
  `1cac02f` *on real hardware too*. The clean test is a **c5.metal-KVM amplifier A/B, `1cac02f` vs.
  the shipped-default (always-block) kernel**: if the shipped valve shows the fingerprint persisting
  at a materially non-zero rate there, the TCG result did not transfer and the fix — or this account
  of it — is wrong. We gate the reliability claim on that run precisely because it can fail; stating
  it in falsification terms is what separates this from an announcement.

## 8. What this says about verification (the methodological contribution)

The intended contribution was a differential refinement proof of a futex. Phase 0 proved the futex
innocent — and then four more components. **The defect lived in the composition of correct
primitives**, in the protocol of who-owes-whom-a-wake during init, not in any primitive. This is the
thesis, and Phase 0 is the evidence *for* it:

> Machine-checkable verification is only as good as the choice of what to verify. Choosing that
> target by intuition — "the futex looks suspect" — would have produced a sincere, tested proof
> *attached to the wrong artifact*. The safeguard is not a better intuition; it is a discipline
> (find and localize the defect empirically before modelling) and a bias toward reading the artifact
> over trusting an inference.

This is the same failure mode, one layer up, as the AI-assisted-development pattern the broader
project keeps hitting: *verification claims that were sincere, tested, and attached to the wrong
artifact* (a "static assets ✅" against a hand-patched app; an AMI that didn't contain the tested
image; a config file gitignored so the repo built for no one but the author). A machine-checked proof
is a structural response because its validity does not depend on anyone's report of what they ran —
but only if it is pointed at the artifact that ships.

## 9. Related work (sketch — to be filled before arXiv)

This is a draft; the section is stubbed to fix the *positioning*, which is where the obvious attacks
land:

- **Unikernels are not new**, and this is not a unikernel-category claim. MirageOS, IncludeOS, OSv,
  Unikraft, and Nanos all run a single application against a thin OS layer; the novelty here is not
  the artifact category but (a) the empirical characterization of the OS surface an *unmodified*
  production managed runtime needs, and (b) the differential result on one primitive. Cite them to
  disclaim scale novelty, not to compete on it.
- **LING** is the direct ancestor — a BEAM-on-a-unikernel that reimplemented the emulator. Its
  failure mode (you inherit the maintenance and the bugs of a second VM) is exactly the motivation
  for running *stock* ERTS, which is what makes this a statement about the OS boundary rather than
  about a new runtime.
- **seL4** verified a microkernel far more thoroughly than anything here. Position honestly: this is
  a *narrow* differential-refinement result on a single primitive, in a kernel that was not designed
  for provability from day one. The interesting part is the *differential* spec (borrow Linux's
  semantics, which ERTS is production-correct against) and the finding that the defect was not in the
  primitive at all — not scale, not rigor relative to seL4.
- **Differential / relational specification** (borrowing a trusted reference implementation's
  observable behavior as the spec) is the lineage for §1's approach; the contribution is applying it
  to the OS/runtime boundary and reporting what it caught (a mis-*chosen* target).

## 10. Next

- **Metal A/B** of `1cac02f` vs. the shipped default on a c5.metal KVM amplifier — turns the TCG
  fingerprint result into a real-hardware reliability number.
- **TLA+**, now with a small confirmed scope: the init-phase registration/lock protocol on one CPU,
  with the futex *trusted* (Phase 0 earned that), and the historical interrupt-context watchdog bug
  re-introduced as the first test that the model has teeth.
- **Verus**, later, on the futex proper (~300 lines) and other self-contained primitives (fd table,
  cpio parser, ring arithmetic) — the algorithmic cores, with the concurrency argument carried by
  the model and the asm/device layer declared out of scope.

---

*Sources: `docs/FUTEX_HISTORY.md` (the full ledger, incl. every sweep and raw-log pointer),
`docs/FUTEX_PROTOCOL.md` (the futex's intended invariants in prose), and commits `1cac02f` (fix) /
this doc's companion docs commit. Amplifier build, instrumented trees, and stall dumps preserved on
the build host.*
