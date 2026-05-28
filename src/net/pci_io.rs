//! Legacy port-IO PCI configuration access (CF8/CFC).
//!
//! Implements the `ConfigurationAccess` trait from `virtio-drivers`
//! using the architectural `0xCF8` / `0xCFC` I/O ports. This works on
//! every x86 chipset — QEMU q35, QEMU i440fx, AWS Nitro — so we use it
//! as the default Tyn config-access path. MMIO ECAM is the alternative,
//! but it requires us to know the right base address, and Nitro doesn't
//! publish MCFG in its ACPI tables, so port-IO is more portable.
//!
//! Standard PCI config space is 256 bytes per function (offset 0..0xFF),
//! which is all we need to read vendor/device IDs, BARs, capabilities,
//! and the command register. PCIe extended config (0x100..0xFFF) is not
//! reachable via port-IO — if we ever need that, switch back to MMIO
//! ECAM for the specific devices that need it.

use virtio_drivers::transport::pci::bus::{ConfigurationAccess, DeviceFunction};

const PCI_CONFIG_ADDRESS: u16 = 0xCF8;
const PCI_CONFIG_DATA:    u16 = 0xCFC;

/// Build the 32-bit address word for port `0xCF8`.
#[inline]
fn config_address(df: DeviceFunction, register_offset: u8) -> u32 {
    (1u32 << 31)                          // ENABLE
        | ((df.bus      as u32) << 16)
        | ((df.device   as u32) << 11)
        | ((df.function as u32) <<  8)
        | ((register_offset as u32) & 0xFC) // dword-aligned
}

#[inline]
unsafe fn outl(port: u16, val: u32) {
    core::arch::asm!("out dx, eax", in("dx") port, in("eax") val,
        options(nomem, nostack, preserves_flags));
}

#[inline]
unsafe fn inl(port: u16) -> u32 {
    let v: u32;
    core::arch::asm!("in eax, dx", in("dx") port, out("eax") v,
        options(nomem, nostack, preserves_flags));
    v
}

pub struct PortIoCam;

impl PortIoCam {
    pub const fn new() -> Self { Self }
}

impl ConfigurationAccess for PortIoCam {
    fn read_word(&self, df: DeviceFunction, register_offset: u8) -> u32 {
        let addr = config_address(df, register_offset);
        // SAFETY: 0xCF8/0xCFC are the architectural PCI config ports.
        // Reads have no memory side effects.
        unsafe {
            outl(PCI_CONFIG_ADDRESS, addr);
            inl(PCI_CONFIG_DATA)
        }
    }

    fn write_word(&mut self, df: DeviceFunction, register_offset: u8, data: u32) {
        let addr = config_address(df, register_offset);
        // SAFETY: same as above.
        unsafe {
            outl(PCI_CONFIG_ADDRESS, addr);
            outl(PCI_CONFIG_DATA, data);
        }
    }

    unsafe fn unsafe_clone(&self) -> Self { Self }
}
