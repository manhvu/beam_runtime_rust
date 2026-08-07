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

## Deliverable

- Which suspect the discriminator localises (or "sequence is fine, go deeper"), booted evidence.
- Whether the node-wedge reproduces in the minimal harness (it shouldn't need dist to reproduce if it's
  a scheduler/lock issue).
- Update Probe 6 in the capability map: verdict FAR → NEAR if the localised bug looks bounded.
