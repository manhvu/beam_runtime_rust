# Distributed-Erlang accept-path hunt — the discriminator experiment

**Status:** open. Localises the Probe 6 (Distributed Erlang) accept-side handshake stall — see
`docs/CAPABILITY_MAP.md`. The verdict there is *FAR as-is, plausibly NEAR once this is pinned*: the
evidence has the shape of a socket-layer bug (bounded fix) rather than a missing subsystem.

## What the spike established

Two Tyn nodes go distributed and bind the listener, but `net_kernel:connect_node` stalls and times out
at exactly `net_setuptime` (7 s). Bisected with a known-good native OTP node: **native → Tyn fails
identically**, so the broken half is Tyn *accepting* an incoming dist connection. Raw TCP to the dist
port works (`gen_tcp:connect` → `{ok, Port}`); the stall is *after* the TCP connection, waiting for
handshake data the initiator already sent. A second, distinct bug: the stall **wedges the node** (eval
shell stops responding).

## Why the accept side is different

The dist listener is not Bandit's `gen_tcp:accept` in a plain loop. It's `inet_tcp_dist` (ERTS's own
driver) doing **async accept → `controlling_process` handoff → active-mode flip → handshake state
machine** on the accepted socket. Nothing else on Tyn exercises that exact sequence. Three suspects:

1. **The accepted socket never delivers its first data (most likely).** Readiness/epoll may follow the
   *listener* fd but not attach to the *accepted* fd across the handoff + active flip, so the acceptor
   blocks in a receive that never fires. Same family as the `gen_tcp:accept` fix, epoll-global-not-
   per-fd, and the connecting-socket `POLLOUT` case.
2. **`{packet, 2}` framing.** The handshake uses 2-byte length-prefixed packets; HTTP works because
   Bandit uses raw mode. If Tyn mishandles `{packet,2}` reassembly on inbound data, the driver waits
   forever for a frame it never completes.
3. **The `controlling_process/2` transfer.** If Tyn doesn't re-route readiness/ownership on that call,
   data is delivered to (or queued for) the wrong process.

## The discriminator — reproduce the sequence OUTSIDE dist (one QEMU node, ~30 lines)

A minimal harness that does exactly what the dist acceptor does, with full visibility and no
distribution machinery: `gen_tcp:listen` → `accept` → (optional `controlling_process` to a waiter) →
`{active, once}` → wait for one message. From the host, `nc` connects and sends one message. Run four
variants and read off which factor breaks it:

| Variant | `{packet,2}` | `controlling_process` handoff | Isolates |
|---|---|---|---|
| A | yes | yes | the exact dist sequence (baseline failure) |
| B | **no** | yes | suspect 2 — B works ⇒ `{packet,2}` is the culprit |
| C | yes | **no** | suspect 3 — C works ⇒ the handoff is the culprit |
| D | no | no | control — should always work |

Reading:
- **A fails, D works** ⇒ the wall is one of the flip/handoff/framing factors (confirms it's the
  sequence, not gen_tcp generally).
- **B works** ⇒ suspect 2 (`{packet,2}` inbound reassembly).
- **C works** ⇒ suspect 3 (`controlling_process` readiness re-route).
- **B and C both fail, D works** ⇒ suspect 1 (accepted-fd readiness across the active-mode flip) — the
  handoff+flip combination, the readiness family we have history in.
- **A works** ⇒ the socket-op sequence is fine; the stall is deeper in the dist state machine
  (challenge/timing) and this theory is wrong — re-open with a handshake-level trace.

The host sends a `{packet,2}` frame as `printf '\x00\x05hello'` (len=5) or raw `printf 'hello'`.

## The second bug (separate trace)

Independently of which suspect wins: a stalled socket receive should not freeze a scheduler. The
node-wedge says the stall holds a lock or blocks a scheduler other work needs. It may share a root
cause with suspect 1 or be a distinct liveness issue; trace it on its own. "A failed join destabilises
the runtime" is disqualifying for the mesh pitch regardless of the handshake fix.

## Result (run — one QEMU node, host sending framed/raw data)

**All socket-op suspects REFUTED — "A works, go deeper."** Every variant returned `<<"hello">>`:

- A (`{packet,2}` + handoff), B (no `{packet,2}`), C (no handoff), D (control) → all `<<"hello">>`.
- **E** — `prim_inet:async_accept` (the call `inet_tcp_dist` *actually* uses, not `gen_tcp:accept`):
  accepted and delivered the data. **Works.**
- **F** — acceptor recv-then-send-back a framed reply: node saw `{recvd,<<"hello">>,sent,ok}` and the
  host received the `{packet,2}` "reply" frame. Full bidirectional round-trip. **Works.**

So sync accept, **async accept**, `{packet,2}` **both directions**, `controlling_process` handoff,
active-mode, passive recv, and acceptor send-flush all work in isolation. The accept-side stall is
**not the socket layer.** It is deeper: the dist handshake's multi-round sequencing or the
**distribution controller** (`erlang:dist_ctrl_*`, the ERTS dist port driver that takes the socket over
during handshake) — a genuinely Tyn-untested subsystem that plain `gen_tcp` can't reproduce.

## PINNED (host-driven, one node — no Nitro needed after all)

A `{packet,2}` byte-level proxy tapped the handshake between a known-good native OTP initiator and
Tyn's acceptor over hostfwd. The tap showed Tyn reaching **step 2** and hanging before **step 3**:

```
INIT→TYN  'N' send_name         ← initiator
TYN→INIT  's' send_status "sok" ← Tyn consumes it and replies  ✅
(silence for 7 s → initiator times out)
```

Step 3 (`send_challenge`) is preceded by `auth:get_cookie/1` → `gen_challenge/0`. Calling each BIF
`gen_challenge/0` uses, in isolation on a live node, pins it to exactly one:

- ✅ `phash2`, `monotonic_time`, `unique_integer`, `statistics(reductions|gc|runtime)`,
  `os:timestamp`, `erlang:timestamp`, `system_time`, `calendar:universal_time` — all return.
- ❌ **`erlang:statistics(wall_clock)` — hangs, wedges the node.**

**Root cause: `erlang:statistics(wall_clock)` DEADLOCKS on Tyn (not a spin).** It is the 6th line of
`gen_challenge/0`, on the acceptor's critical path, so the handshake hangs there. The node-wedge is the
**same deadlock**, not a separate bug.

*Corrected characterisation (verify the artifact):* an earlier draft said "busy-spins." It does not.
(1) The OTP-27 source for `erts_wall_clock_elapsed_both` is straight-line — no loop — structurally the
same as the `runtime` branch that works. (2) **QEMU CPU is 0.0 % during the hang** (idle/HLT), so it is
**blocked, not spinning**. It deadlocks inside `time_sup.r.o.get_time` / the time-correction path, which
takes `erts_get_time_mtx` (a **futex-based mutex**) — a wait that never wakes. The wall clock *advances*
(read/sleep/read → ~2 s deltas; just offset at 1970), so this is **not** the kvmclock offset. It is
**futex / thread-progress** family — the same subsystem as the boot-stall/`FUTEX_BLOCKING` work.

## Step 1 (frozen vs advancing) — ANSWERED

Advancing from 1970 (~2 s deltas over a 2 s sleep; abs value ≈ uptime). So per the plan's own map, the
subtler case — and the CPU-idle measurement sharpens it from "reads a value it doesn't expect" to
"blocks on a lock that never releases." The kvmclock/RTC *offset* fix would not touch it.

## Ladder (WALLCLOCK_LADDER) — cheapest-first, and where it stopped

- **Rung 1 (`system_info`) — config is NORMAL, not a mismatch.** `time_correction=true`,
  `time_warp_mode=multi_time_warp`, both sources `clock_gettime` (`CLOCK_REALTIME`/`CLOCK_MONOTONIC`) at
  ns resolution, **`parallel=yes`** (reads meant to be lockless). Nothing a normal Linux ERTS wouldn't
  report. So the deadlock is not a config/source mismatch — no cheap collapse.
- **Deadlock vs crash — it's a deadlock.** After a `statistics(wall_clock)` call the serial log shows
  **no** `exit_group`/crash/error (even accounting for quiet mode), and QEMU CPU is **0 %**. The
  emulator is alive but frozen — a genuine block, not an abort.
- **Rung 2 (source-diff) — version-EXACT, and it does NOT explain the block.** `erl_time_sup.c` in the
  OTP-27.3.4.2 tag is `VSN = 15.2.7.1` = exactly Tyn's beam (no version skew — the trap the ladder
  warned about is ruled out). In that source, `statistics(wall_clock)` → `erts_wall_clock_elapsed_both`
  is **lockless straight-line** and calls the **same** `time_sup.r.o.get_time` pointer that
  `erlang:monotonic_time` (via `erts_get_monotonic_time`) uses — and monotonic *works*. Both paths share
  the one lockless getter; only `wall_clock` blocks. The C source therefore does **not** account for the
  deadlock: it is neither a config mismatch, nor version skew, nor a lock the wall-clock C path uniquely
  takes.

**Checkpoint reached (per the ladder's "don't grind on momentum").** What remains is genuinely a deep
runtime/futex interaction: the source says these two paths are identical below `get_time`, so the
divergence is not visible at the C level — it needs **kernel-side futex instrumentation** (Rung 4: which
futex address the `wall_clock` call blocks on and whether a wake is ever issued — the `ever=0`/lost-wake
technique from the boot-stall work) or a **disassembly of the beam's `statistics` BIF**. That is a real
diagnostic session, not a cheap rung. Decision deferred to the user: keep chasing (Rung 4) now, or bank
this as a documented **NEAR** (deadlock pinned to `statistics(wall_clock)` on the dist critical path,
root-cause not yet localised) and move the roadmap to tmpfs / TLS-sidecar.

*(Rung 3 — "is the correction updater running?" — is largely mooted by Rung 2: the shared getter is
lockless and monotonic already reads corrected time fine, so a not-running updater would break monotonic
too. Worth a glance during Rung 4 but not the leading hypothesis anymore.)*

## Step 3/4 (after the fix)

The tap cleared everything *up to* step 3; the later rounds (challenge-reply, ack) and the `dist_ctrl`
controller takeover are still unexercised. Re-run the single-node tap, then the two-node Nitro handshake,
once the deadlock is fixed.

## Deliverable — DONE (this session)

- Pinned round: hangs at step 3 (`gen_challenge` → `statistics(wall_clock)`).
- Mechanism: a **deadlock** (CPU idle) in the ERTS time-correction lock, **not** a spin, **not** the
  clock offset — futex/thread-progress family. Corrected from the earlier "busy-spin" claim.
- Node-wedge: same root cause (the deadlock), resolved.
- Probe 6 verdict: FAR → **NEAR** (bounded-if-a-lost-wake; futex/thread-progress-adjacent).
