//! smoltcp `Interface` construction, shared by virtio-net (static IP) and
//! ENA (DHCP-assigned IP).

use smoltcp::iface::{Config, Interface};
use smoltcp::phy::Device;
use smoltcp::time::Instant;
use smoltcp::wire::{EthernetAddress, HardwareAddress, Ipv4Address};

/// Guest IP (QEMU user-mode networking default).
pub const KERNEL_IP: Ipv4Address = Ipv4Address::new(10, 0, 2, 15);
/// Default gateway (QEMU user-mode networking).
pub const GATEWAY_IP: Ipv4Address = Ipv4Address::new(10, 0, 2, 2);
/// Subnet prefix length.
pub const PREFIX_LEN: u8 = 24;

/// Build a smoltcp `Interface` for `device` with the given MAC and no IP.
/// The caller assigns an address (static for virtio, DHCP for ENA).
pub fn build<D: Device + ?Sized>(device: &mut D, mac: [u8; 6]) -> Interface {
    let mac = EthernetAddress(mac);
    let mut config = Config::new(HardwareAddress::Ethernet(mac));
    // SAFETY: RDTSC is available on all x86_64 CPUs.
    config.random_seed = unsafe { core::arch::x86_64::_rdtsc() };

    let mut iface = Interface::new(config, device, Instant::from_millis(0));
    iface.set_any_ip(true);
    iface
}
