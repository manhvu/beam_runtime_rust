//! ENA BAR0 register offsets and bit definitions.
//!
//! Mirrors `ena_regs_defs.h` from amzn-drivers
//! (https://github.com/amzn/amzn-drivers/tree/master/kernel/linux/ena).

// Register offsets (from start of BAR0).
pub const VERSION:            u64 = 0x00;
pub const CONTROLLER_VERSION: u64 = 0x04;
pub const CAPS:               u64 = 0x0c;
pub const CAPS_EXT:           u64 = 0x10;
pub const AQ_BASE_LO:         u64 = 0x14;
pub const AQ_BASE_HI:         u64 = 0x18;
pub const AQ_CAPS:            u64 = 0x1c;
pub const ACQ_BASE_LO:        u64 = 0x20;
pub const ACQ_BASE_HI:        u64 = 0x24;
pub const ACQ_CAPS:           u64 = 0x28;
pub const AQ_DB:              u64 = 0x2c;
pub const ACQ_TAIL:           u64 = 0x30;
pub const AENQ_CAPS:          u64 = 0x34;
pub const AENQ_BASE_LO:       u64 = 0x38;
pub const AENQ_BASE_HI:       u64 = 0x3c;
pub const AENQ_HEAD_DB:       u64 = 0x40;
pub const AENQ_TAIL:          u64 = 0x44;
pub const INTR_MASK:          u64 = 0x4c;
pub const DEV_CTL:            u64 = 0x54;
pub const DEV_STS:            u64 = 0x58;
pub const MMIO_REG_READ:      u64 = 0x5c;
pub const MMIO_RESP_LO:       u64 = 0x60;
pub const MMIO_RESP_HI:       u64 = 0x64;

// DEV_CTL bits.
pub const DEV_CTL_DEV_RESET: u32 = 1 << 0;

// DEV_STS bits.
pub const DEV_STS_READY:             u32 = 1 << 0;
pub const DEV_STS_AQ_RESTART_REQ:    u32 = 1 << 1;
pub const DEV_STS_RESET_IN_PROGRESS: u32 = 1 << 2;
pub const DEV_STS_RESET_FINISHED:    u32 = 1 << 3;
pub const DEV_STS_FATAL_ERROR:       u32 = 1 << 4;

// CAPS bit layout.
//   bits  0..5    : Contains reset timeout, in units of 100ms
//   bits  8..15   : MMIO read timeout, in units of 100ms
//   bits 16..23   : DMA addr width (in bits)
//   bits 24..31   : admin completion buffer size (in 64-byte units)
pub fn caps_reset_timeout_ms(caps: u32) -> u32 {
    ((caps >> 0) & 0x3f) * 100
}
