# Wall clock: give Tyn a real absolute time source (kvmclock / RTC)

**Status: RTC boot-seed SHIPPED (`src/rtc.rs` + `syscall.rs` clk_id split).** `CLOCK_REALTIME` /
`gettimeofday` now serve real UTC, seeded once from the CMOS/RTC at boot; `CLOCK_MONOTONIC` is
untouched. Validated: QEMU full path (`DateTime.utc_now` → real 2026 time, advancing at the right
rate, monotonic intact) and the Nitro RTC read (`[clock] RTC seed: unix=…s (UTC)` = real time on real
hardware). **kvmclock** remains the documented precision follow-on (below), not built. Original
"1970 + uptime" bug and the sizing analysis are kept below for the record.

**Assumptions (documented, confirmed on the targets):** the RTC presents **UTC** (QEMU + Nitro/KVM —
seed matched host UTC to the second); **BCD** encoding + **24-hour** mode (both auto-detected from
status register B; binary/12-hour paths handled anyway); RTC year is two digits, century from register
`0x32` if plausible else `20xx`. **Limitation:** second-resolution, and it drifts with the TSC over
long uptimes (no NTP, no correction loop — that's the kvmclock upgrade). Fine for `utc_now`, log
timestamps, and TLS cert-date checks.

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
> **Retraction — this was never a clock problem.** An earlier note here claimed
> `erlang:statistics(wall_clock)` "deadlocks" and blocked native distributed Erlang. That was wrong
> (a capture-bug misattribution; see Probe 6). The real dist blocker was `erlang:statistics(runtime)` →
> `getrusage(RUSAGE_SELF)` → `ENOSYS` → `erts_exit` (a **missing syscall crash**, not a deadlock, not the
> clock), now fixed with a `getrusage` stub. It has nothing to do with this ticket. This ticket is
> purely the **1970 epoch offset** (kvmclock/RTC) — kept separate and still open on its own merits
> (in-guest TLS cert dates + absolute-time correctness).

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

## Sizing & recommendation (TLS_SIDECAR.md Part 2 — verified against the source, not built)

**Current wiring, confirmed in `src/syscall.rs`:** `sys_clock_gettime` (nr 228) *ignores* its
`_clk_id` and returns `monotonic_ns()` for every clock; `gettimeofday` (nr 96) does the same.
`monotonic_ns()` is `raw_tsc * 1000 / freq_mhz` — TSC-since-boot, never seeded with absolute time.
That single fact is the whole "1970" bug: there is exactly one place wall-time is produced, and it has
no real base. **No RTC/CMOS read exists anywhere in the tree** (grep-confirmed).

**Bounded fix = RTC/CMOS boot-seed. Rough size ≈ 70–90 lines, one file + two call sites.** Leading
candidate over kvmclock:

| Option | Size | Notes |
|---|---|---|
| **RTC/CMOS (ports 0x70/0x71)** | ~60 LOC read + ~10 LOC wiring | one-shot at boot: poll the UIP bit, read sec/min/hr/day/mon/yr, BCD→binary, days-since-1970→Unix secs. Works on QEMU *and* Nitro (KVM exposes the emulated RTC in UTC). **Recommended first.** |
| kvmclock | ~120–150 LOC | MSR `MSR_KVM_WALL_CLOCK_NEW` + a shared page; higher precision, the "right" VM answer, but more surface. A later precision upgrade, not needed for correctness. |
| network time (HTTP `Date`/NTP) | — | fallback only; don't ship as primary. |

**Mechanism (no rework of the monotonic source):** at boot, `WALL_OFFSET_NS = rtc_unix_ns -
monotonic_ns()`; store it. Then split the `clk_id` that `sys_clock_gettime` currently ignores:
`CLOCK_REALTIME (0)` → `monotonic_ns() + WALL_OFFSET_NS`; `CLOCK_MONOTONIC (1)` → `monotonic_ns()`
unchanged. Same `+WALL_OFFSET_NS` in `gettimeofday`. That's the entire change.

**Benefits — verified, not assumed (one fix, many payoffs):** because *all* wall-time in the guest
flows through exactly those two syscalls, seeding `CLOCK_REALTIME` fixes **every** absolute-time
consumer at once — `DateTime.utc_now/0`, `System.system_time/0`, `:os.system_time/1`, Logger/telemetry
timestamps, cookie/JWT absolute expiry, and (once the crypto NIF exists) TLS cert-date validation.
`erlang:monotonic_time` is untouched (still `CLOCK_MONOTONIC`), so scheduling/timeouts/the futex path
are unaffected.

**Not this session's build** (per the directions: size, don't necessarily build). It is small and
high-value, but it needs its own Nitro acceptance run (`DateTime.utc_now` returns real UTC ±seconds and
advances) — a bounded, separable piece of work. Distinct from the retracted `statistics(runtime)`/
`getrusage` item above: that was a missing-syscall crash; this is boot-time seeding.
