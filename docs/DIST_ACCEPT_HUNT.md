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
- ❌ **`erlang:statistics(wall_clock)` — hangs forever, wedges the node.**

**Root cause: `erlang:statistics(wall_clock)` busy-spins on Tyn.** It is the 6th line of
`gen_challenge/0`, on the acceptor's critical path, so the handshake hangs there. The node-wedge is the
**same spin** (monopolises the scheduler on `-smp 1`; holds the ERTS time lock on multi-scheduler
Nitro), *not* a separate bug. Every other clock BIF works, so this is not a broad "wall clock broken" —
it is specifically `statistics(wall_clock)`'s time-correction/elapsed path spinning on Tyn's clock.

## The fix + what remains

- **Fix:** make `statistics(wall_clock)` return instead of spin — an ERTS time-path bug on Tyn's clock
  behaviour. This is **clock-adjacent**: same subsystem as `docs/WALL_CLOCK.md` (kvmclock/RTC), and now
  a concrete, high-value reason to do that work (it unblocks native clustering).
- **Confirm after the fix:** the tap cleared everything *up to* step 3; the later rounds
  (challenge-reply, ack) and the `dist_ctrl` controller takeover are still unexercised. Re-run the
  two-node Nitro handshake once the BIF is fixed to confirm end-to-end join + traffic + liveness.

## Deliverable — DONE

- Pinned round: hangs at step 3 (`gen_challenge` → `statistics(wall_clock)`).
- Node-wedge: same root cause (the spin), resolved.
- Probe 6 verdict: FAR → **NEAR** (bounded, clock-adjacent, feeds `docs/WALL_CLOCK.md`).
