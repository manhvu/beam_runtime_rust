//! Kernel heap backed by a static array.
//!
//! Uses `linked_list_allocator` as the global allocator. After
//! `init_static()`, `alloc::Box`, `alloc::Vec`, etc. are available.

use linked_list_allocator::LockedHeap;

/// Heap size: 16 MiB (static array, no page table ops needed).
///
/// 2 MiB was the historical default and exhausts during sustained
/// network load: each accepted TCP socket reserves smoltcp buffers
/// (8 KiB rx + 8 KiB tx = 16 KiB), plus smoltcp's internal `SocketSet`
/// `Vec` reallocations cost ~216 KiB at growth thresholds. After
/// ~250 sustained connections the kernel panicked on an
/// `alloc::alloc` failure (see directions/STRESS_TEST.md).
///
/// 16 MiB gives ~1024 simultaneous socket buffers' worth of
/// capacity. Memory layout: kernel BSS lives between 0x0F00_0000
/// and the ELF source copy at 0x1400_0000 (80 MiB headroom);
/// 16 MiB leaves ~12 MiB room for further BSS growth.
const HEAP_SIZE: usize = 16 * 1024 * 1024;

static mut HEAP: [u8; HEAP_SIZE] = [0; HEAP_SIZE];

#[global_allocator]
static ALLOCATOR: LockedHeap = LockedHeap::empty();

/// Initialize the global allocator from a static array.
///
/// Must be called once before any heap allocation.
pub fn init_static() {
    // SAFETY: Called once during single-threaded boot. The static HEAP
    // array is not accessed from any other location.
    unsafe {
        let start = core::ptr::addr_of_mut!(HEAP) as usize;
        ALLOCATOR.lock().init(start, HEAP_SIZE);
    }
}
