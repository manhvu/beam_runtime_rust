# Inbound throughput / large-upload 400 — RESOLVED (QEMU-only artifact; no kernel fix)

**Status: RESOLVED — there was no kernel bug. The symptom was a QEMU/SLIRP/TCG emulation artifact.**
A real-Nitro (ENA) reality-check settled it: inbound is ~4 MB/s and real `Plug.Upload` multipart
uploads round-trip **byte-exact** on real hardware; the only limit is the intentional tmpfs cap. Two
prescribed kernel fixes (the RX window, then the "recv drains one segment" loop) were disproven from
source/measurement *before* being shipped — this doc is the record so the dead ends aren't re-run.
Companion to `INBOUND_BODY.md` and `RECV_FIX.md` (both premises did not hold) and `SEND_CORRUPTION.md`.

## RESOLUTION — real Nitro (ENA), one `c5.large` instance (torn down)

The build host runs QEMU/virtio/SLIRP under TCG; **that is not representative of Nitro's ENA path.**
Deploying the *unmodified* code and testing over ENA:

| Test | Nitro (ENA) | QEMU/SLIRP |
|---|---|---|
| RAW body 1 / 2 / 4 MiB | 0.27 / 0.49 / 0.99 s (**~4 MB/s**) | 6.3 / 14.7 s (**~146 KB/s**) |
| `Plug.Upload` multipart 1 MiB | **200 · byte-exact** | 400 |
| `Plug.Upload` multipart 2 MiB | **200 · byte-exact** | 400 |
| `Plug.Upload` multipart 3 MiB (isolated) | **200 · byte-exact** | 400 |
| multipart 3.9 MiB / 4× concurrent 1 MiB | 400 — **tmpfs 4 MiB cap (ENOSPC)**, not inbound | — |

So inbound throughput is ~25× faster on real hardware, uploads work byte-exact to ~3 MiB, and the
*only* remaining failure is the documented **4 MiB tmpfs cap** (`CAP` in `src/tmpfs.rs`): a 3.9 MiB
body, or concurrent uploads summing past 4 MiB, ENOSPC. Raising the cap (a one-line constant, traded
against the 16 MiB kernel heap) is the lever for larger/concurrent uploads — a separate decision, not
an inbound-path bug. **No kernel change was made for INBOUND_BODY.**

The QEMU throttle (~146 KB/s, window-independent, 1 MSS per ~9 ms ≈ the 100 Hz poll tick) is real but
QEMU-only: near-zero-RTT SLIRP + timer-driven `net::poll()` ingesting ~one segment per tick. It does
not occur on ENA (interrupt-driven). Worth knowing for local perf testing; not a shipped-path bug.

## The (pre-resolution) diagnosis trail — kept so the dead ends aren't re-run

## Symptom

Large `Plug.Upload` multipart uploads (≳1 MiB) return **HTTP 400**:
`%Bandit.HTTPError{message: "Body read timeout"}` → wrapped by `Plug.Parsers.parse/5` into a
`ParseError` → 400. Bandit's body read uses a 15 s default `read_timeout`; any body that needs >15 s
trips it.

## What is NOT the cause (each ruled out by measurement or source)

| Hypothesis | Verdict | Evidence |
|---|---|---|
| Body truncated on receive | **No** | bare `gen_tcp` recv-loop, `{active,once}`, and `recv(s,1048576)` all return the whole body byte-exact; `/raw` reads 3 MiB fine |
| tmpfs write path | **No** | the 400 is a body-**read** timeout, before any tmpfs write; tmpfs stores 2 MiB + 8 concurrent byte-exact |
| Socket layer / readiness | **No** | all recv modes deliver the full body; `epoll_wait` is level-triggered (`poll_socket` reports `POLLIN` whenever `can_recv()`) |
| Multipart-parser-specific | **No** | `/raw` (plain `read_body`) and `/upload` (multipart) are *identically* slow; same `Bandit…read_data` |
| **RX receive window** (`LISTENER_BUF_SIZE` 2 KiB) | **Not on QEMU** (unproven on Nitro) | bumped RX buffer 2 KiB→32 KiB → `/raw` 1 MiB stayed 6.3 s, **no change**. Window-independent under QEMU |
| **recv drains one segment** (`RECV_FIX.md`) | **No — provable no-op** | smoltcp 0.13.0 `recv_slice` → `dequeue_slice` runs two `dequeue_many_with` passes over the byte ring (pre/post wrap) and returns *all* available up to `len`. The rx buffer is `RingBuffer<u8>`; segments are reassembled into it — there is no "one segment" to stop at. Looping `recv_slice` changes nothing |

## What IS measured (the real symptom)

**Inbound throughput ≈ 140–166 KB/s, identical across all paths** (bare `gen_tcp`, `/raw`, `/upload`),
**linear in size** (1 MiB ≈ 6.3 s, 2 MiB ≈ 12–15 s), and **window-independent**. That is ~1 MSS
(1460 B) per **~9 ms** — suspiciously the **100 Hz timer tick (10 ms)**. So only ~one segment is
*buffered* when `recv` runs, and `recv_slice` correctly returns that one segment because that is all
there is — not because it truncates.

## The two live candidates (not yet separated)

1. **RX buffer size = 2048** (`LISTENER_BUF_SIZE`). Caps how much can be buffered/advertised as window.
   The *send* twin of this (`LISTENER_TX_BUF_SIZE`) was raised 2 KiB→32 KiB and measured "~34 KB/s on
   Nitro" at 2 KiB — so on **real hardware** the window is a real throttle. A receive-window bump may
   therefore help on Nitro even though it did nothing on QEMU.
2. **Poll cadence.** During a blocked recv the scheduler idles (HLT, blocking-futex valve) and
   `net::poll()` runs ~100 Hz (timer-driven), ingesting ~one segment per cycle regardless of window.
   This would explain the window-independence on QEMU (near-zero-RTT SLIRP).

Both can be true; they are separable by instrumenting a live node (bytes buffered when recv runs, recv
size per call, `net::poll()` calls/sec during a transfer).

## Crucial caveat: everything above is **QEMU/virtio/SLIRP under TCG**

The build host boots `-device virtio-net-pci`; **real Nitro uses ENA** and is interrupt-driven, not
100 Hz-timer-polled. QEMU/SLIRP is known to differ (the socket code's own comments: "masked on QEMU
because the SLIRP host bridge dropped the excess SYNs"). So the ~146 KB/s throttle **may be a
QEMU-only artifact**. The next step is a **Nitro reality-check**: deploy the current (unmodified) code
and measure whether large uploads even fail on ENA before attempting any fix.

## Standing lesson

Two directions files in a row (`INBOUND_BODY.md` window premise, `RECV_FIX.md` recv-coalesce premise)
prescribed fixes whose premises dissolved on reading the actual artifact (the socket buffer sizes; the
smoltcp source). Same lesson as the dist `getrusage` saga and `SEND_CORRUPTION.md`: **verify the
premise against the source/measurement before building on it.** The measured fact — inbound is
~146 KB/s on QEMU — is solid; every *mechanism* claim needs the one-level-deeper read.
