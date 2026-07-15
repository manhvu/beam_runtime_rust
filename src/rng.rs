//! Kernel CSPRNG seeded from the CPU hardware RNG (RDSEED / RDRAND).
//!
//! beam.smp's crypto runs in user space and obtains randomness via getrandom(2)
//! (and /dev/urandom), which the kernel must serve. Tyn has no other entropy
//! source, so this is the root of trust for all session/CSRF/token crypto.
//!
//! Design: at boot we seed a ChaCha20 CSPRNG from the hardware RNG (8 x 64-bit
//! reads, XOR-folded to a 256-bit seed), preferring RDSEED (true entropy) over
//! RDRAND. Every read checks the carry flag and retries — ignoring CF is the
//! classic bug that yields silently-constant "randomness". If neither RDRAND nor
//! RDSEED is present we PANIC at boot rather than fall back to a weak source:
//! weak randomness that boots is far more dangerous than a kernel that refuses.
//! The stream is reseeded with fresh hardware entropy every RESEED_BYTES.

use crate::serial_println;
use core::sync::atomic::{AtomicU64, Ordering};
use rand_chacha::ChaCha20Rng;
use rand_core::{RngCore, SeedableRng};
use spin::Mutex;

#[derive(Clone, Copy)]
pub struct HwRng {
    pub rdrand: bool,
    pub rdseed: bool,
}

static HW: Mutex<HwRng> = Mutex::new(HwRng { rdrand: false, rdseed: false });
static CSPRNG: Mutex<Option<ChaCha20Rng>> = Mutex::new(None);
static SINCE_RESEED: AtomicU64 = AtomicU64::new(0);
const RESEED_BYTES: u64 = 1 << 20; // reseed every 1 MiB of output

/// RDRAND: CPUID leaf 1, ECX bit 30. RDSEED: CPUID leaf 7 subleaf 0, EBX bit 18.
fn detect() -> HwRng {
    use core::arch::x86_64::{__cpuid, __cpuid_count};
    // SAFETY: CPUID is always available on x86_64.
    unsafe {
        let rdrand = __cpuid(1).ecx & (1 << 30) != 0;
        let rdseed = __cpuid_count(7, 0).ebx & (1 << 18) != 0;
        HwRng { rdrand, rdseed }
    }
}

/// One 64-bit hardware-random word. Checks the carry flag on every instruction
/// (the intrinsics return 1 on success / CF=1, 0 on failure) and retries with a
/// bounded count. Prefers RDSEED; falls back to RDRAND. None if all attempts
/// fail — the caller treats that as a fatal seeding error.
fn hw_word(hw: &HwRng) -> Option<u64> {
    use core::arch::x86_64::{_rdrand64_step, _rdseed64_step};
    let mut v: u64 = 0;
    if hw.rdseed {
        // RDSEED fails more often by design (it waits for real entropy).
        for _ in 0..1024 {
            if unsafe { _rdseed64_step(&mut v) } == 1 {
                return Some(v);
            }
            core::hint::spin_loop();
        }
    }
    if hw.rdrand {
        for _ in 0..64 {
            if unsafe { _rdrand64_step(&mut v) } == 1 {
                return Some(v);
            }
            core::hint::spin_loop();
        }
    }
    None
}

/// Gather a 256-bit seed from 8 hardware words XOR-folded to 4 (defense against
/// a single weak read).
fn gather_seed(hw: &HwRng) -> [u8; 32] {
    let mut words = [0u64; 8];
    for w in words.iter_mut() {
        *w = hw_word(hw).expect("[rng] hardware RNG failed while seeding");
    }
    let mut seed = [0u8; 32];
    for i in 0..4 {
        let folded = words[i] ^ words[i + 4];
        seed[i * 8..i * 8 + 8].copy_from_slice(&folded.to_ne_bytes());
    }
    seed
}

/// Detect the hardware RNG and seed the CSPRNG. Panics if no hardware RNG.
pub fn init() {
    let hw = detect();
    serial_println!("[rng] hw RNG: RDRAND={} RDSEED={}", hw.rdrand, hw.rdseed);
    if !hw.rdrand && !hw.rdseed {
        panic!("[rng] no hardware RNG (RDRAND/RDSEED) — refusing to boot rather than serve weak entropy");
    }
    *HW.lock() = hw;
    let seed = gather_seed(&hw);
    *CSPRNG.lock() = Some(ChaCha20Rng::from_seed(seed));
    SINCE_RESEED.store(0, Ordering::Relaxed);
    serial_println!("[rng] ChaCha20 CSPRNG seeded from hardware");
}

/// Fill `buf` with CSPRNG output, reseeding from fresh hardware entropy after
/// every RESEED_BYTES.
pub fn fill(buf: &mut [u8]) {
    let mut guard = CSPRNG.lock();
    let rng = guard.as_mut().expect("[rng] fill before init");
    rng.fill_bytes(buf);

    let total = SINCE_RESEED.fetch_add(buf.len() as u64, Ordering::Relaxed) + buf.len() as u64;
    if total >= RESEED_BYTES {
        SINCE_RESEED.store(0, Ordering::Relaxed);
        let hw = *HW.lock();
        // Forward-secret reseed: XOR fresh hardware entropy with current stream
        // output so the new state depends on both.
        let mut newseed = gather_seed(&hw);
        let mut cur = [0u8; 32];
        rng.fill_bytes(&mut cur);
        for i in 0..32 {
            newseed[i] ^= cur[i];
        }
        *rng = ChaCha20Rng::from_seed(newseed);
    }
}

/// Fill `len` bytes at user pointer `buf` with CSPRNG output.
///
/// # Safety
/// `buf` must point to `len` writable, identity-mapped bytes.
pub unsafe fn fill_raw(buf: *mut u8, len: usize) {
    let slice = core::slice::from_raw_parts_mut(buf, len);
    fill(slice);
}
