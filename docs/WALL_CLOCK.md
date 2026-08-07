# Wall clock: give Tyn a real absolute time source (kvmclock / RTC)

**Status:** open, unstarted. **Type:** named prerequisite — this ticket exists because the epoch
clock keeps getting *rediscovered* mid-probe instead of being tracked as a dependency. It now gates at
least two roadmap items; file it once, reference it from both.

## The problem

Tyn's `CLOCK_REALTIME` is not a wall clock — it is *time since boot*. Both `clock_gettime(2)`
(`src/syscall.rs` `sys_clock_gettime`, nr 228) and `gettimeofday(2)` (nr 96) return `monotonic_ns()`,
a TSC-derived count that starts near zero at boot. Nothing reads the RTC/CMOS at boot and there is no
kvmclock, so `:os.system_time/1`, `DateTime.utc_now/0`, `System.system_time/0`, and Erlang timestamps
all read **1970 + uptime**.

Monotonic time is fine (scheduling, futex, timeouts, `:erlang.monotonic_time`). This ticket is
specifically about **absolute / wall-clock** time.

## What it gates (why it's worth a standing ticket)

1. **In-guest TLS certificate dates** (`docs/CAPABILITY_MAP.md` Probe 5b, Path A). TLS validates a
   peer cert's `notBefore`/`notAfter`. At 1970 every real cert is "not yet valid," so cert validation
   fails *even after* the crypto NIF is fixed. Any in-guest TLS-to-DB or TLS-to-API path is gated on
   this. (The near-term TLS answer — a sidecar, Path B — avoids it precisely by validating certs in a
   process that has a real clock.)
2. **Absolute-time correctness generally.** App-generated timestamps (`inserted_at`/`updated_at` when
   set in-app rather than by the DB, JWT `exp`/`iat`, signed-URL expiry, log/telemetry timestamps,
   cache TTLs keyed on wall time, cookie `Max-Age` vs `Expires`) are all wrong by ~55 years. Most are
   silent — which is why this keeps surfacing late.
3. **`erlang:statistics(wall_clock)` busy-spins → native distributed Erlang is blocked** (capability
   map Probe 6 / `docs/DIST_ACCEPT_HUNT.md`). This is not the epoch *offset* — every other clock BIF
   returns fine. It is a distinct symptom in the *same* time subsystem: `statistics(wall_clock)`'s
   elapsed-time path (via ERTS time correction) **hangs** on Tyn's clock behaviour, wedging the
   scheduler. `dist_util:gen_challenge/0` calls it on the handshake critical path, so two Tyn nodes
   cannot cluster and a failed join wedges the node. Fixing the clock/time-correction path here is the
   concrete unblock for the "native Erlang mesh" positioning — a high-value, bounded reason to do this
   ticket. Whether the kvmclock/RTC base alone fixes the spin, or the ERTS time-correction interaction
   needs its own fix, is the open question; investigate `statistics(wall_clock)`'s ERTS path
   (`erts_get_time`/time-correction) against Tyn's `clock_gettime` behaviour.

## The ask

Establish a real wall-clock base at boot and serve it from `CLOCK_REALTIME`, keeping the existing
monotonic source for `CLOCK_MONOTONIC`:

- **Boot base**: read it once at startup. Two candidate sources, ideally both with a fallback order:
  - **kvmclock** (the KVM/Nitro paravirtual clock, MSRs `MSR_KVM_SYSTEM_TIME_NEW` /
    `MSR_KVM_WALL_CLOCK_NEW`) — the correct source on the actual deploy target (Nitro/KVM). Gives
    wall-clock seconds + a monotonically-advancing system-time page.
  - **RTC/CMOS** (ports `0x70`/`0x71`) as a portable fallback (works under plain QEMU/TCG too).
- **Serve**: `CLOCK_REALTIME = wall_base + (monotonic_ns() - boot_monotonic)`. Leave
  `CLOCK_MONOTONIC` as-is. Split the two `clk_id`s in `sys_clock_gettime` (currently ignored,
  `_clk_id`) and in `gettimeofday`.

## Acceptance

- On real Nitro: `DateTime.utc_now/0` in the serial eval shell returns the actual current UTC time
  (± a few seconds), and advances correctly over a minute.
- Under local QEMU: same, via the RTC fallback.
- A TLS handshake against a server with a normally-dated cert no longer fails on `notBefore`/
  `notAfter` for date reasons (once the crypto NIF exists — coordinate with the Probe 5b Path-A work).

## Notes / sequencing

- This is independent of and can land before the crypto-NIF work, but Path-A TLS needs **both**.
- Watch the TSC/RDTSC interplay: `monotonic_ns()` already normalizes per-CPU TSC offsets
  (`src/syscall.rs` ~1978, `sys_clock_gettime` path); the wall base only needs adding, not a rework of
  the monotonic source.
- Reference from: `docs/CAPABILITY_MAP.md` (Probe 5b, synthesis item 2) and `docs/DEPLOY.md`
  (Limitations — "epoch wall clock").
