# Kernel-stack allocator inventory

**Purpose.** BUG-1's Path-A fix (`directions/REDZONE_FIX_RIGHT.md`) reserves a
per-thread *preempt region* found via `gs:[0]` (the running thread's kernel-stack
top). If any live path that puts a value into `gs:[0]` is missed, the fix
silently reintroduces the red-zone clobber on that path — and because Tyn
identity-maps 0–4 GiB, that miss is silent heap corruption, not a fault (see
`BUGS.md` → systemic hazard). **So completeness here is a safety property, not a
nicety.** This document enumerates every kernel-stack path and *proves* the
`gs:[0]`-relevant set is exactly two.

Verified against the tree at commit `a69e8d1` (2025-08). Re-verify with the greps
in the completeness proof below if the scheduler/syscall code changes.

## Completeness proof — the `gs:[0]` set is exactly two

`gs:[0]` is the per-CPU **kernel stack top** the syscall entry loads
(`syscall.rs::syscall_entry`: `mov rsp, gs:[0]`). The preempt trampoline's
`syscall` uses it, so **only stacks that reach `gs:[0]` matter for BUG-1.**

**Why the `gs:[0]` set IS the fix's coverage set (not just "stacks in general").**
Path A *locates* the per-thread preempt region by **reading `gs:[0]` at preemption
time** — it reserves the region relative to whatever kernel-stack top `gs:[0]`
holds for the running thread. So the set of values `gs:[0]` can ever hold is
*exactly* the set of paths the fix must place a reservation on; proving that set
complete proves the fix's coverage complete. A stack that never reaches `gs:[0]`
is never where the trampoline's `syscall` runs, so it needs no reservation — which
is why the dead/non-`gs:[0]` paths below can be safely excluded, not merely
"probably fine."

1. **`gs:[0]` is written in exactly three places** (`grep "gs:\[0\]" src/`):
   - `syscall.rs:64` — init: `PERCPU_SYSCALL[0].kernel_stack = syscall_stack_0_top`.
   - `syscall.rs:76` — `set_current_kernel_stack(kstack)` (the runtime writer).
   - `syscall.rs:185` — `mov gs:[0], rax` in `syscall_entry`, where
     `rax = [rsp+16]` = **the same** thread's saved kstack top (re-store for the
     next syscall; introduces no new value).
2. **`set_current_kernel_stack` callers** (`grep "set_current_kernel_stack"`):
   - `sched.rs:{337,568,642,793}` — all pass `THREADS[tid].kernel_stack_top`.
   - `thread.rs:215` — **DEAD** (see below).
3. **`THREADS[].kernel_stack_top` is set at exactly two sites** (`grep
   "kernel_stack_top:" src/sched.rs`):
   - `sched.rs:385` — thread 0 (main): `= syscall_stack_0_top`.
   - `sched.rs:466` — every `clone()`'d thread: `= KSTACK_NEXT` allocation.

→ The complete live set of `gs:[0]` kernel-stack tops is **{ (A) syscall_stack_0,
(B) sched.rs KSTACK_NEXT allocations }**. Nothing else reaches `gs:[0]`.

### Dead / irrelevant paths — proven, not assumed
- **`thread.rs` (its `KSTACK_NEXT`, `CONTEXTS`, `spawn`, `context_switch`).** DEAD.
  It's `pub mod thread` in lib.rs but has **no external callers**: `grep -r
  "thread::" src/` outside `src/thread.rs` is empty; `sys_clone` uses
  `sched::spawn`; `main.rs` runs `sched::init`, not any thread.rs init. So
  `thread.rs:215`'s `set_current_kernel_stack` never runs. (Candidate for deletion
  — see `BUGS.md`/paydown. Left in place for this audit; **not a live gs:[0]
  source**.)
- **`syscall_stack_1` (`syscall.rs:102-104`, static 32 KiB).** DEAD — declared but
  **unreferenced** (`grep "syscall_stack_1"` = 3 hits, all the definition). It sits
  *directly above* `syscall_stack_0_top`, i.e. 32 KiB of unused space above thread
  0's kernel stack (relevant to A below).
- **`percpu.rs::PerCpuData.kernel_stack` (`[u8; 16384]`).** UNUSED FIELD —
  declared + zero-init'd, **never read** (`grep ".kernel_stack" src/percpu.rs` =
  decl+init only). The TSS uses `ist_stack` for IST1; Tyn runs ring 0 so `rsp0`
  is never taken. Not a gs:[0] source.

## The two live allocators (the BUG-1 fix input)

### (A) `syscall_stack_0` — thread 0 (main scheduler)
- **Where:** `syscall.rs:99-101`, static `.space 32768` → `syscall_stack_0_top`.
- **Size / base:** 32 KiB, static BSS, single instance.
- **Can host the preempt region?** **YES, for free** — `syscall_stack_1` (dead,
  32 KiB) sits immediately above `syscall_stack_0_top`, so `[syscall_stack_0_top ..
  +N]` is already unused. The fix can place the preempt region there without any
  reservation change (or repurpose part of syscall_stack_1).

### (B) `sched.rs KSTACK_NEXT` — every clone()'d thread (the ERTS fleet)
- **Where:** `sched.rs:431-434`, `KSTACK_NEXT.fetch_add(16384)` per thread;
  `kstack_top = base + 16384`; stored as `THREADS[tid].kernel_stack_top`
  (`sched.rs:466`). Base region starts at the `KSTACK_NEXT` initial value.
- **Size / base:** 16 KiB each, bump-allocated contiguously → **thread N+1's base
  == thread N's top**. This is the whole ERTS fleet: normal schedulers, dirty
  schedulers, async threads — including the **small-stack dirty/aux threads** whose
  underflow was the naive fix's 25% crash.
- **Can host the preempt region?** **Only with a reservation change** — because
  allocations are contiguous, `[kstack_top .. +N]` is the *next* thread's stack
  base. The fix MUST bump by `16384 + PREEMPT_SIZE` (reserve the region *above*
  each top), or the preempt writes corrupt the neighbour. **This is the path the
  naive fix broke.**

## Non-`gs:[0]` stacks (full picture; outside BUG-1's preempt concern)

The trampoline's `syscall` never loads these into `rsp`, so they don't take the
preempt region — but recorded so the map is complete:

| Stack | Where | Size | Role |
|---|---|---|---|
| Boot stack | `multiboot.S:111-113`, `.boot_stack` | `BOOT_STACK_SIZE` | Boot only, before threads (`movabs rsp, boot_stack_top`). |
| Idle stacks | `sched.rs:143` `IDLE_STACKS` | 4 KiB / CPU | Per-CPU idle context (`IDLE_CTX[cpu].rsp`). |
| IST1 stack | `percpu.rs:21` `ist_stack` → TSS.IST1 | 16 KiB / CPU | The **timer interrupt** itself runs here (where the preempt handler executes). |
| AP boot stacks | `smp.rs:60-62` `alloc_zeroed` | 64 KiB / AP | AP bring-up; **`-smp 1` ⇒ none allocated.** |
| User (BEAM) stack | `main.rs:260` | 2 MiB | Initial BEAM user stack; per-thread user stacks come from `clone(stack=…)`. This is the stack whose **red zone** BUG-1 clobbers. |

`mov rsp` sites all classified (`grep "mov rsp" src/*.rs src/*.S`): `sched.rs:597`
& `1207` restore a thread's saved kernel `rsp` (into A/B); `sched.rs:1160` &
`syscall.rs:2474` switch to a **user** stack (clone child / jump_to_user);
`thread.rs:164/395` are DEAD; `multiboot.S:71` is the boot stack. None is a new
`gs:[0]` source.

## Bottom line for BUG-1 Path A
Reserve the preempt region on **two** paths: (A) free above `syscall_stack_0_top`
(dead syscall_stack_1 space); (B) increase `sched.rs KSTACK_NEXT`'s per-thread bump
by `PREEMPT_SIZE`. Cover both and the fix is complete; the dead paths (thread.rs,
syscall_stack_1, percpu.kernel_stack) need nothing. The standing `redzone_probe`
(dosed across many threads) will catch a missed path.
