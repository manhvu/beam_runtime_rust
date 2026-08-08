//! CMOS/RTC read — seed real wall-clock time at boot.
//!
//! Tyn's `CLOCK_REALTIME` is otherwise TSC-since-boot (1970 + uptime). This
//! module reads the battery-backed RTC once at startup so `syscall.rs` can serve
//! a real UTC wall clock (see `seed_wall_clock`). Second-resolution only; it
//! drifts with the TSC over long uptimes — fine for `DateTime.utc_now`, log
//! timestamps, and TLS cert-date checks. kvmclock (paravirt) is the documented
//! precision follow-on (`docs/WALL_CLOCK.md`), not built here.
//!
//! ## Target assumptions (confirmed on QEMU + Nitro/KVM)
//! - The RTC presents **UTC** (not localtime) — both QEMU (`-rtc base=utc`, the
//!   default the OVMF/SeaBIOS path uses) and Nitro/KVM. A localtime RTC would
//!   seed a skewed clock; if a future target used localtime this is where it'd
//!   need a tz offset.
//! - **24-hour** mode (status register B bit 1 set) — near-universal on these
//!   targets; the 12-hour path is handled anyway.
//! - **BCD** encoding (status register B bit 2 clear) — the usual BIOS default;
//!   the binary path is handled anyway.

use x86_64::instructions::port::Port;

const CMOS_ADDR: u16 = 0x70;
const CMOS_DATA: u16 = 0x71;

/// Read a CMOS register. Leaves the NMI-disable bit (0x80) clear.
///
/// # Safety
/// Direct port I/O; caller runs at boot with interrupts effectively quiescent.
unsafe fn cmos_read(reg: u8) -> u8 {
    Port::<u8>::new(CMOS_ADDR).write(reg);
    Port::<u8>::new(CMOS_DATA).read()
}

/// Status register A, bit 7: an RTC update is in progress (registers unstable).
fn update_in_progress() -> bool {
    unsafe { cmos_read(0x0A) & 0x80 != 0 }
}

#[derive(PartialEq, Clone, Copy)]
struct RawTime {
    sec: u8,
    min: u8,
    hour: u8,
    day: u8,
    mon: u8,
    year: u8,
    cent: u8,
}

/// # Safety: port I/O.
unsafe fn read_raw() -> RawTime {
    RawTime {
        sec: cmos_read(0x00),
        min: cmos_read(0x02),
        hour: cmos_read(0x04),
        day: cmos_read(0x07),
        mon: cmos_read(0x08),
        year: cmos_read(0x09),
        cent: cmos_read(0x32), // century register — present on most modern chipsets
    }
}

/// Read the RTC and return Unix seconds (UTC), or `None` if the value is
/// obviously implausible (so the caller keeps the safe 1970+uptime fallback
/// rather than seeding a garbage clock).
pub fn read_rtc_unix_secs() -> Option<u64> {
    // Correctness step: never read mid-update. Wait for UIP to clear, then read,
    // and re-read until two consecutive reads are identical — this defends
    // against a rollover landing between our per-register reads.
    let mut last = unsafe {
        while update_in_progress() {}
        read_raw()
    };
    for _ in 0..10 {
        unsafe {
            while update_in_progress() {}
            let cur = read_raw();
            if cur == last {
                break;
            }
            last = cur;
        }
    }

    let status_b = unsafe { cmos_read(0x0B) };
    let is_bcd = status_b & 0x04 == 0; // bit 2 clear => BCD
    let is_12h = status_b & 0x02 == 0; // bit 1 clear => 12-hour
    let dec = |v: u8| -> u64 {
        if is_bcd {
            ((v & 0x0F) as u64) + (((v >> 4) & 0x0F) as u64) * 10
        } else {
            v as u64
        }
    };

    let sec = dec(last.sec);
    let min = dec(last.min);
    // Hour: in 12-hour mode the PM flag is bit 0x80 of the raw byte (before BCD).
    let hour = if is_12h {
        let pm = last.hour & 0x80 != 0;
        let h = dec(last.hour & 0x7F);
        if pm { (h % 12) + 12 } else { h % 12 }
    } else {
        dec(last.hour)
    };
    let day = dec(last.day);
    let mon = dec(last.mon);
    let yy = dec(last.year);
    // Century: use register 0x32 if it decodes to something plausible (19–21),
    // else assume 20xx. RTC year is two digits; this is the documented assumption.
    let cent = dec(last.cent);
    let year = if (19..=21).contains(&cent) {
        cent * 100 + yy
    } else {
        2000 + yy
    };

    // Reject garbage so we fall back to 1970+uptime instead of a wild clock.
    if !(1..=12).contains(&mon)
        || !(1..=31).contains(&day)
        || hour > 23
        || min > 59
        || sec > 60
        || !(2020..=2100).contains(&year)
    {
        return None;
    }

    let days = days_since_epoch(year, mon as u8, day as u8);
    Some(days * 86_400 + hour * 3_600 + min * 60 + sec)
}

fn is_leap(y: u64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

/// Days from 1970-01-01 to `year-month-day` (proleptic Gregorian, all inputs
/// already validated by the caller).
fn days_since_epoch(year: u64, month: u8, day: u8) -> u64 {
    let mut days = 0u64;
    let mut y = 1970;
    while y < year {
        days += if is_leap(y) { 366 } else { 365 };
        y += 1;
    }
    const MDAYS: [u64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut m = 1u8;
    while m < month {
        days += MDAYS[(m - 1) as usize];
        if m == 2 && is_leap(year) {
            days += 1;
        }
        m += 1;
    }
    days + (day as u64 - 1)
}
