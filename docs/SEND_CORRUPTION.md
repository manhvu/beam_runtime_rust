# TCP send corruption + static-asset delivery — consolidated history

**Status: RESOLVED.** Two kernel commits close it: `fc8d468` (honor partial writes in `sys_writev`)
and `70d3002` (implement `sendfile(2)` + `dup(2)`). Clean-clone-validated on real Nitro; the
regression is codified byte-exact in `tests/` (Layer 1 of `TEST_SUITE.md`).

This document is the authoritative record of the saga — the ruled-out hypotheses, the repro, the
**white-box trace technique that cracked it after four black-box hypotheses failed**, the two root
causes, and the standing operational lesson. It is the matched pair to `FUTEX_HISTORY.md`: same
hypothesis / test / verdict shape, so the two read together.

---

## 1. The bug

Multiple rapid `gen_tcp:send` calls on one socket produced byte-CORRECT length but WRONG content —
non-deterministically, at **2048-byte boundaries**. A single large send was clean; the file read
was clean. It surfaced through a chunked-send path (the ThousandIsland "bridge", itself a
workaround for `:file.sendfile` returning `enosys`), which is why static assets were the visible
symptom: a 125 KB `app.js` served as `200` with `content-length: 125737` but a corrupt/short body.

**Why it was dangerous:** a `200 OK` with wrong bytes is invisible to status-only checks. Every
prior "green" that checked status and not content was suspect — including a 2000/2000 regression
sweep. `status ≠ correctness` is the through-line of both this saga and the sendfile one.

---

## 2. Repro (corrected — the first stated repro was wrong)

- **Corrupts:** `/chk/65536/8` and larger (chunked = ≥2 `gen_tcp:send` on one socket). **Clean:**
  `/chk/8192/4` and single-send (`send_resp`) at every size incl. 1.5 MB.
- Corruption lands at **2048-byte boundaries** (= `LISTENER_BUF_SIZE`, the socket TX ring).
- **Non-deterministic**; concurrency amplifies it.
- **Fires at `-smp 1`.** ⚠️ An early direction note asserted "clean at `-smp 1`"; that was **wrong**
  — the corruption reproduces at `-smp 1` because QEMU's device model runs the virtio DMA
  asynchronously, so the guest being single-CPU does not serialize the TX path. (Recorded here
  because it is the first of several premises that collapsed on contact with the artifact — see §7.)
- **Goes clean under per-packet serial logging** (which slows the TX path) — a Heisenbug. This is
  the fact that forced the non-perturbing technique in §5.

Harness: a varied `0..255` body (never all-X — an all-X payload cannot detect reordering or
duplication, which is this bug's exact signature) via `/sz/:n` (inline) and `/chk/:n/:k` (chunked),
hash-checked against the known md5. Now `tests/setup-test-app.sh` builds this into a stock app.

---

## 3. Hypothesis ledger

Four black-box hypotheses, each a clean single-variable test on QEMU, all rejected. Recorded so
nobody re-runs them.

| # | Hypothesis | Test | Verdict |
| --- | --- | --- | --- |
| S1 | **POLL_OPT flush timing** — `sys_write` skips `net::poll()` and flushes via `epoll_wait`, racing the drain against the next enqueue at a buffer boundary | Forced `net::poll()` after every `sendto` | **Rejected** — no fix |
| S2 | **Multiple in-flight descriptors** — TX buffer reused while >1 descriptor is in flight | Instrumented `pending_tx` depth | **Rejected** — depth stays ≤1; no descriptor-token reuse; no queue-full |
| S3 | **Premature free + buffer-address reuse** — a freed TX `Vec` address is reused and refilled before the device DMAs the previous packet | Quarantine: keep 256 freed TX buffers alive so addresses aren't reused | **Rejected** — no fix |
| S4 | **Store-buffer / DMA visibility** — CPU stores not visible to the device at notify | `fence(SeqCst)` + `mfence` before `transmit_begin` | **Rejected** — no fix |

Black-box guess-and-test on a flaky TCG box was not converging. The obvious buffer-lifecycle
hypotheses were exhausted. That is the point at which to switch to white-box.

---

## 4. Root cause (two, in a chain)

### 4a. `sys_writev` discarded already-written bytes on a later-iovec `-EAGAIN`

The OTP `inet` driver batches queued `gen_tcp:send` binaries into **one `writev` with multiple
iovecs**. Old `sys_writev` looped `sys_write` per iovec and, on the first negative return,
`return`ed it — **throwing away the bytes earlier iovecs had already enqueued**. When iovec 0
enqueued 2048 bytes into the full 2048-byte TX ring and iovec 1 hit the full ring (`-EAGAIN`),
`writev` returned `-EAGAIN`, so the driver concluded *nothing* was written, retried the whole
`writev`, and re-enqueued iovec 0's block — **forever**. smoltcp faithfully transmitted each
re-enqueue at an **advancing TCP sequence number**, so the response's Content-Length filled with
one repeated stale 2048-byte block while the real remainder was never sent.

**Fix (`fc8d468`):** honor POSIX partial-write semantics — return the bytes already written when a
later iovec errors (surface the error only if zero were written), and stop at a short write so the
caller resumes at exactly `total`. ERTS's own loop resumes on `POLLOUT`. This is the same
partial-write class that later recurred one layer up in `sendfile`.

### 4b. Static assets: missing `sendfile(2)` **and** `dup(2)`, not a missing ERTS feature

`:file.sendfile` returned `{error, enosys}` — but **not** because musl's `beam.smp` lacks sendfile.
It has `HAVE_SENDFILE=1`, and `inet_drv.c` calls the Linux `sendfile(2)` syscall (nr 40) directly.
Tyn simply hadn't implemented syscall 40, so it returned `-ENOSYS`. ERTS also calls `dup(2)` (nr 32)
on the file fd first (`dup_file_fd = dup(raw_file_fd)`); with `dup` unimplemented the fd was bogus,
`sendfile` failed, and **Bandit emitted a 500 into the already-committed `200` response** — that
nested 500 was the "231-byte body" that looked like a truncation all along.

**Fix (`70d3002`):** implement both kernel-side — `sys_sendfile` streams file→socket through a
bounded 4 KiB buffer honoring partial writes (§4a's lesson), `vfs::dup` duplicates a cpio fd. This
**retired the ThousandIsland bridge** (a per-app dependency patch that was never in the repo): the
kernel now serves sendfile the standard way for every app and transport.

**The dependency:** `fc8d468` was correct-but-*unreachable* on a clean clone until `70d3002` landed
(without sendfile→multi-send, `sendfile` 500s before any multi-send happens). It is now load-bearing
under the sendfile drain.

---

## 5. The technique: the non-perturbing in-memory trace (reusable)

The Heisenbug (§2: serial logging slows the TX path and hides the bug) means any instrumentation
that changes timing destroys the evidence. The method that cracked it — **generalizes to any
timing-sensitive corruption bug:**

1. **In-memory ring, no I/O on the hot path.** A fixed static array. Per event (here: per TX
   packet) record a tiny fixed record — for TX: `{tcp_seq, len, first_byte, FNV-1a hash of the
   payload}`. One hash pass, zero serial. Near-zero added latency, so the timing bug stays live.
2. **Dump off the hot path.** Trigger the dump by a side channel that isn't the hot path — here,
   opening a magic VFS path (`/tyn/txdump`) flushed the ring to serial *after* the request. The slow
   serial never touches the send timing.
3. **Compare against known-correct bytes, offline.** With a varied `0..255` body (or the actual
   file), the expected hash at every stream offset is computable ahead of time. Diff recorded vs
   expected.

What it revealed, in two passes:
- **Device-side trace** (payload hash at device hand-off): the device buffer held a **frozen
  2048-byte block == the file's 3rd block, repeated 58× at advancing sequence numbers**, and the
  client received exactly that. Buffer content == wire content ⇒ **the device is faithful; smoltcp
  was handed stale bytes.** (Localized the bug to *buffer, not wire* — the one question black-box
  testing couldn't answer.)
- **Send-side trace** (`{requested_len, first source byte, accepted count}` at `send_slice`): a
  perfect 2-cycle — iovec 0 (`first=app.js[4096]`) accepted 2048, iovec 1 (`first=app.js[8192]`)
  blocked, **repeated ~18,000×** with the offset stuck at 4096. That is `writev` re-feeding the
  same offset because it discarded the partial write (§4a). SND total 155 after the fix vs 18,464
  before — the caller had been doing ~120× the necessary work.

Keep the instrumentation until content-integrity passes — it proves the buffer is correct *at
hand-off*, which is strictly stronger than "the client happened to get the right bytes on one run."

---

## 6. Fixes that landed

| Fix | Effect |
| --- | --- |
| `sys_writev` honors partial writes (`fc8d468`) | Multi-send responses byte-exact; ends the frozen-block re-send loop |
| `sys_sendfile` (syscall 40), bounded 4 KiB stream, partial-write honored (`70d3002`) | `:file.sendfile` works; static assets serve on a clean clone |
| `vfs::dup` (syscall 32) (`70d3002`) | ERTS's `dup(raw_file_fd)` before sendfile now returns a valid fd |
| ThousandIsland bridge **removed** | The kernel serves sendfile the standard way — no per-app dependency patch, no version coupling |
| `check_origin` (app config, not kernel) | LiveView WS was `403`ing cross-origin on a bare IP; `check_origin: false` for a throwaway demo (prod: set the real host list) |

Validation (real Nitro, clean clone, content not status): app.js/app.css byte-exact; a 1.5 MB
asset byte-exact across many TX windows; `/chk` multi-send byte-exact; N=25 concurrent all
identical; interactive LiveView counter increments over the socket.

---

## 7. Standing lesson: read the tree, not your inference of it

Three confidently-stated premises about this bug were **wrong**, and each collapsed in *minutes* the
moment someone read the actual artifact instead of reasoning about it:

| Premise (stated confidently) | Reality (found by reading the artifact) |
| --- | --- |
| "syscall 40 is never called" | `inet_drv.c:13858` calls `sendfile(2)` directly; the earlier kernel trace was flawed |
| "musl `beam.smp` was built without sendfile" | the configured OTP tree has `#define HAVE_SENDFILE 1` |
| the LiveView "stale" token is a Tyn defect | the hand-rolled test client was missing the session cookie a browser sends |
| (bonus, §2) "the corruption is clean at `-smp 1`" | it reproduces at `-smp 1` — the device DMA is async |

**The standing operational lesson:** *inference about the build has a bad track record here — read
the tree.* Read the config header, read the driver source in the actual image, read the git commit,
send the real handshake. This is not a footnote about one bug; it is the same failure mode that
`FUTEX_HISTORY.md` records ("a fix that works on an easier workload isn't a fix", the 100%-on-echo
claim that masked 82.8%-on-Phoenix). The two documents share it deliberately.

## 8. Corrections to earlier notes

- The `project_sendfile_static_bug` root cause was originally recorded as "musl `beam.smp` built
  without sendfile support." **Wrong** (§4b): sendfile is compiled in; the kernel lacked syscalls
  40 and 32. Corrected in the memory.
- The "static assets ✅" capability-matrix entry reflected a **hand-patched** app for weeks; a clean
  clone 500'd on every asset. It is genuinely ✅ only as of `70d3002`, and now guarded by a
  clean-clone test that fails hard if any dependency is patched (`tests/setup-test-app.sh`).
