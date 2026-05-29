//! ENA admin queue — Phase 2 milestone A.
//!
//! Brings up the admin submission/completion queue pair and runs a
//! `GET_FEATURE(DEVICE_ATTRIBUTES)` round-trip to read the MAC address,
//! max queue count, and max MTU. This proves the device processes admin
//! commands; the I/O-queue data path builds on top of it.
//!
//! Layout/offset references are to amzn-drivers
//! `kernel/linux/common/ena_com/ena_{admin,regs}_defs.h` and the admin-init
//! sequence in `ena_com.c:ena_com_admin_init()`.
//!
//! Completions arrive via device DMA into host memory (the CQ); x86 DMA to
//! write-back memory is cache-coherent, so a plain volatile read of the CQ
//! phase bit is sufficient — no cache maintenance and no readless MMIO path
//! is needed here. The only MMIO *read* is DEV_STS, which Phase 1 confirmed
//! reads correctly via direct access on Nitro.

use super::regs;
use crate::drivers::virtio::hal::TynHal;
use crate::serial_println;
use crate::syscall::monotonic_ns;
use core::ptr::{copy_nonoverlapping, read_volatile, write_bytes};
use virtio_drivers::{BufferDirection, Hal, PAGE_SIZE};

const ADMIN_QUEUE_DEPTH: u16 = 32;
const ADMIN_ENTRY_SIZE: usize = 64; // both SQ and CQ entries are 64 bytes
const AENQ_DEPTH: u16 = 16;
const AENQ_ENTRY_SIZE: usize = 64;

// Admin opcodes (ena_admin_aq_opcode).
const OP_GET_FEATURE: u8 = 8;
// Feature ids (ena_admin_aq_feature_id).
const FEAT_DEVICE_ATTRIBUTES: u8 = 1;

// aq/acq common-desc phase bit (bit 0 of the flags byte).
const PHASE_MASK: u8 = 0x1;

const ADMIN_CMD_TIMEOUT_NS: u64 = 1_000_000_000; // 1 s, matches ENA_REG_READ_TIMEOUT scale

/// Device attributes read back from GET_FEATURE(DEVICE_ATTRIBUTES).
pub struct DeviceAttrs {
    pub mac: [u8; 6],
    pub max_mtu: u32,
    pub phys_addr_width: u32,
    pub supported_features: u32,
}

/// Allocate `bytes` of page-aligned, zeroed DMA memory. Identity-mapped, so
/// the returned address is both the virtual and physical address.
fn dma_alloc_zeroed(bytes: usize) -> u64 {
    let pages = bytes.div_ceil(PAGE_SIZE);
    let (paddr, vaddr) = TynHal::dma_alloc(pages, BufferDirection::Both);
    // SAFETY: freshly bump-allocated region of `pages` pages, exclusively ours.
    unsafe { write_bytes(vaddr.as_ptr(), 0, pages * PAGE_SIZE); }
    debug_assert_eq!(paddr, vaddr.as_ptr() as u64, "identity mapping broken");
    paddr
}

pub struct AdminQueue {
    bar0: u64,
    sq_base: u64,
    cq_base: u64,
    depth: u16,
    sq_tail: u16,
    sq_phase: u8,
    cq_head: u16,
    cq_phase: u8,
    curr_cmd_id: u16,
}

impl AdminQueue {
    /// Initialize the admin SQ/CQ (and AENQ) and arm the device.
    /// `bar0` must already have BUS_MASTER + MEMORY_SPACE enabled.
    pub fn init(bar0: u64) -> Result<Self, &'static str> {
        // Device must report ready (Phase 1 saw dev_sts=0x1, so no reset).
        let dev_sts = unsafe { regs::read32(bar0, regs::DEV_STS) };
        if dev_sts & regs::DEV_STS_READY == 0 {
            return Err("device not ready");
        }

        let sq_base = dma_alloc_zeroed(ADMIN_QUEUE_DEPTH as usize * ADMIN_ENTRY_SIZE);
        let cq_base = dma_alloc_zeroed(ADMIN_QUEUE_DEPTH as usize * ADMIN_ENTRY_SIZE);
        let aenq_base = dma_alloc_zeroed(AENQ_DEPTH as usize * AENQ_ENTRY_SIZE);

        unsafe {
            // SQ/CQ base addresses (identity-mapped: high half is 0 under 4 GiB).
            regs::write32(bar0, regs::AQ_BASE_LO, sq_base as u32);
            regs::write32(bar0, regs::AQ_BASE_HI, (sq_base >> 32) as u32);
            regs::write32(bar0, regs::ACQ_BASE_LO, cq_base as u32);
            regs::write32(bar0, regs::ACQ_BASE_HI, (cq_base >> 32) as u32);

            // Caps: depth in low 16 bits, entry size in high 16 bits. These
            // writes arm the queues, so they come after the base addresses.
            let aq_caps = (ADMIN_QUEUE_DEPTH as u32 & regs::AQ_CAPS_DEPTH_MASK)
                | ((ADMIN_ENTRY_SIZE as u32) << regs::AQ_CAPS_ENTRY_SIZE_SHIFT);
            regs::write32(bar0, regs::AQ_CAPS, aq_caps);
            regs::write32(bar0, regs::ACQ_CAPS, aq_caps);

            // AENQ: the driver configures it during admin init. We don't
            // process async events yet, but the device expects it set up.
            regs::write32(bar0, regs::AENQ_BASE_LO, aenq_base as u32);
            regs::write32(bar0, regs::AENQ_BASE_HI, (aenq_base >> 32) as u32);
            let aenq_caps = (AENQ_DEPTH as u32 & regs::AQ_CAPS_DEPTH_MASK)
                | ((AENQ_ENTRY_SIZE as u32) << regs::AQ_CAPS_ENTRY_SIZE_SHIFT);
            regs::write32(bar0, regs::AENQ_CAPS, aenq_caps);
        }

        serial_println!("[ena] admin queue initialized (depth={})", ADMIN_QUEUE_DEPTH);

        Ok(AdminQueue {
            bar0,
            sq_base,
            cq_base,
            depth: ADMIN_QUEUE_DEPTH,
            sq_tail: 0,
            sq_phase: 1,
            cq_head: 0,
            cq_phase: 1,
            curr_cmd_id: 0,
        })
    }

    /// Submit a 64-byte admin command and poll the CQ for its completion.
    /// Returns the 64-byte completion entry on success.
    fn submit_and_poll(&mut self, mut cmd: [u8; ADMIN_ENTRY_SIZE]) -> Result<[u8; ADMIN_ENTRY_SIZE], &'static str> {
        let mask = self.depth - 1;
        let cmd_id = self.curr_cmd_id;

        // aq_common_desc: command_id[0..2] (bits 11:0), flags[3] phase bit.
        cmd[0] = (cmd_id & 0xff) as u8;
        cmd[1] = ((cmd_id >> 8) & 0x0f) as u8;
        cmd[3] |= self.sq_phase & PHASE_MASK;

        let tail_masked = (self.sq_tail & mask) as usize;
        // SAFETY: tail_masked < depth; sq_base holds depth*64 zeroed bytes.
        unsafe {
            let dst = (self.sq_base as *mut u8).add(tail_masked * ADMIN_ENTRY_SIZE);
            copy_nonoverlapping(cmd.as_ptr(), dst, ADMIN_ENTRY_SIZE);
        }

        self.curr_cmd_id = (self.curr_cmd_id + 1) & mask;
        self.sq_tail = self.sq_tail.wrapping_add(1);
        if self.sq_tail & mask == 0 {
            self.sq_phase ^= 1;
        }

        // Ring the doorbell with the new tail.
        unsafe { regs::write32(self.bar0, regs::AQ_DB, self.sq_tail as u32); }

        // Poll the completion queue for the phase flip.
        let start = monotonic_ns();
        loop {
            let entry_off = self.cq_head as usize * ADMIN_ENTRY_SIZE;
            // SAFETY: cq_head < depth; CQ is device-DMA'd, x86-coherent.
            let flags = unsafe { read_volatile((self.cq_base as *const u8).add(entry_off + 3)) };
            if flags & PHASE_MASK == self.cq_phase {
                let mut out = [0u8; ADMIN_ENTRY_SIZE];
                // SAFETY: same in-bounds CQ entry.
                unsafe {
                    copy_nonoverlapping(
                        (self.cq_base as *const u8).add(entry_off),
                        out.as_mut_ptr(),
                        ADMIN_ENTRY_SIZE,
                    );
                }
                self.cq_head += 1;
                if self.cq_head == self.depth {
                    self.cq_head = 0;
                    self.cq_phase ^= 1;
                }
                let status = out[2];
                if status != 0 {
                    serial_println!("[ena] admin command failed: status={}", status);
                    return Err("admin command non-zero status");
                }
                return Ok(out);
            }
            if monotonic_ns().wrapping_sub(start) > ADMIN_CMD_TIMEOUT_NS {
                return Err("admin command timeout");
            }
            core::hint::spin_loop();
        }
    }

    /// GET_FEATURE(DEVICE_ATTRIBUTES) — response is inline in the CQ entry,
    /// no control buffer required (ena_com.c:ena_com_get_feature_ex with
    /// control_buff_size==0).
    pub fn get_device_attributes(&mut self) -> Result<DeviceAttrs, &'static str> {
        let mut cmd = [0u8; ADMIN_ENTRY_SIZE];
        cmd[2] = OP_GET_FEATURE; // aq_common_desc.opcode
        // feat_common starts at byte 16: flags[16], feature_id[17], version[18].
        cmd[17] = FEAT_DEVICE_ATTRIBUTES;

        let resp = self.submit_and_poll(cmd)?;

        // acq_common_desc is 8 bytes; ena_admin_device_attr_feature_desc
        // overlays response_specific_data starting at byte 8:
        //   +8  impl_id            (u32)
        //   +12 device_version     (u32)
        //   +16 supported_features (u32)
        //   +20 capabilities       (u32)
        //   +24 phys_addr_width    (u32)
        //   +28 virt_addr_width    (u32)
        //   +32 mac_addr[6]
        //   +38 flow_steering_max_entries (u16)
        //   +40 max_mtu            (u32)
        let rd32 = |o: usize| {
            u32::from_le_bytes([resp[o], resp[o + 1], resp[o + 2], resp[o + 3]])
        };
        let mut mac = [0u8; 6];
        mac.copy_from_slice(&resp[32..38]);

        Ok(DeviceAttrs {
            mac,
            supported_features: rd32(16),
            phys_addr_width: rd32(24),
            max_mtu: rd32(40),
        })
    }
}
