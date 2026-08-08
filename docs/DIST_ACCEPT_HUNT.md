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

## RESOLVED — it was a missing syscall (`getrusage`), and native clustering now works

A `{packet,2}` byte-level proxy tapped the handshake between a known-good native OTP initiator and
Tyn's acceptor over hostfwd. The tap showed Tyn reaching **step 2** and dying before **step 3**:

```
INIT→TYN  'N' send_name         ← initiator
TYN→INIT  's' send_status "sok" ← Tyn consumes it and replies  ✅
(silence → initiator times out)
```

Step 3 (`send_challenge`) is preceded by `auth:get_cookie/1` → `gen_challenge/0`, which calls
`erlang:statistics(runtime)` (line 5) then `erlang:statistics(wall_clock)` (line 6). Health-gated,
per-BIF isolation (each call preceded by a `1+1 → 2` health check, full-output capture, timed) pins it:

- ✅ everything returns — including `statistics(wall_clock)` (`>> 13797`), `atomics:exchange`, etc.
- ❌ **`erlang:statistics(runtime)` — kills the node.**

**Root cause: a missing `getrusage(2)` syscall.** `statistics(runtime)` → `erts_runtime_elapsed_both`
→ `getrusage(RUSAGE_SELF, &now)`. Tyn had **no handler for nr 98**, so it returned `ENOSYS`, and ERTS
treats getrusage failure as **fatal**: `if (getrusage(...) != 0) erts_exit(ERTS_ABORT_EXIT, ...)`. The
serial log during the call is unambiguous — `getrusage(RUSAGE_SELF, _) failed: 38` then
`exit_group(127)`: the node **exits**. Not a deadlock, not the clock, not the socket layer, not
`dist_ctrl`.

**Fix + confirmation.** A `getrusage` stub in `src/syscall.rs` (return `0`, zeroed `struct rusage`).
Re-running the tap: the acceptor now emits `send_challenge`, the handshake completes
(`send_challenge_reply` → `send_challenge_ack`), the dist controller takes over (Erlang term frames flow
both directions), and `net_kernel:connect_node` → **`true`** (96 ms) with `nodes()` populated. The node
stays healthy. The back-half that looked "unexercised" runs.

## The correction, kept honest (the −0x70 lesson, three drafts deep)

Earlier drafts of this doc said the wall was `statistics(wall_clock)` deadlocking on the ERTS
time-correction futex (`erts_get_time_mtx`), tied it to the wall clock / `WALL_CLOCK.md`, and climbed a
whole "cheapest-first" ladder (system_info config-normal; source version-exact; "deep futex interaction,
checkpoint"). **All of it was a castle on a misattribution.** Two mistakes:

1. **A capture bug.** A bare `>> ` shell prompt (no value) was read as a returned value, so
   `statistics(runtime)` — which actually *died* — was logged "works," and blame fell on the *next*
   call in `gen_challenge`, `statistics(wall_clock)`. A health-gated re-test (`1+1 → 2` first, full raw
   output) showed `wall_clock` **works** and `runtime` is the one that dies.
2. **"0 % CPU + wedged" ≠ deadlock.** It was the emulator having **exited** (`exit_group`), not a block.
   Checking the *serial log* during the call — which the ladder's discipline finally forced — showed the
   `getrusage` abort immediately. The whole time-correction/futex analysis dissolved.

The lesson the ladder encoded held: the contradiction ("identical code, different behaviour") meant the
read had stopped too early — but the resolution was not deeper in ERTS's time machinery, it was that the
premise ("`wall_clock` is the culprit") was itself a measurement artifact. Verify the artifact, then
verify the *measurement*.

## What remains — the two-node Nitro confirmation

Confirmed on a single Tyn node + a native OTP peer (over hostfwd). The last validation is **two Tyn
nodes on Nitro**: `connect_node` both directions, `rpc:call`, a ~1 MB term hash-checked, liveness across
several `net_ticktime` cycles, `nodedown` on kill. Plus moving the cookie from the kernel `-setcookie`
scaffolding to `boot.config` (per-image). That turns "buildable, handshake-proven" into "shippable mesh."

## Deliverable — DONE (this session)

- Real root cause: **missing `getrusage(2)` syscall** → `statistics(runtime)` → `erts_exit` → node exit,
  on the dist handshake critical path. Not a deadlock, not the clock.
- Fix: `getrusage` stub (`src/syscall.rs`); handshake completes end-to-end, nodes cluster, node healthy.
- Probe 6 verdict: NEAR → **BUILDABLE** (pending the two-node Nitro back-half + cookie→boot.config).
- Corrected the earlier `statistics(wall_clock)`/deadlock/futex misdiagnosis in Probe 6 and this doc.
