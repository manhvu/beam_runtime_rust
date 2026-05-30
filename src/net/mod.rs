//! Network stack — device abstraction (virtio-net or ENA), smoltcp
//! interface, socket layer.

pub mod device;
pub mod ena;
pub mod interface;
pub mod pci_io;
pub mod socket;
pub mod tcp_echo;

use smoltcp::iface::{Interface, SocketSet};
use smoltcp::phy::{Device, DeviceCapabilities, RxToken, TxToken};
use smoltcp::time::Instant;
use virtio_drivers::transport::pci::PciTransport;

use crate::net::device::{VirtioNetDevice, VirtioRxToken, VirtioTxToken};
use crate::net::ena::device::{EnaDevice, EnaRxToken, EnaTxToken};
use crate::serial_println;

/// The physical NIC backing smoltcp. virtio-net on QEMU, ENA on AWS Nitro.
/// An enum (not `dyn Device`) because smoltcp's `Device` has GAT token
/// types and isn't object-safe; the enum dispatches per call.
pub enum NetDevice {
    Virtio(VirtioNetDevice<PciTransport>),
    Ena(EnaDevice),
}

impl NetDevice {
    /// Free completed TX descriptors before a poll cycle.
    fn drain_tx(&mut self) {
        match self {
            NetDevice::Virtio(d) => d.drain_completed_tx(),
            NetDevice::Ena(d) => d.drain_tx(),
        }
    }
}

pub enum NetRxToken {
    Virtio(VirtioRxToken),
    Ena(EnaRxToken),
}

pub enum NetTxToken<'a> {
    Virtio(VirtioTxToken<'a, PciTransport>),
    Ena(EnaTxToken<'a>),
}

impl Device for NetDevice {
    type RxToken<'a> = NetRxToken;
    type TxToken<'a> = NetTxToken<'a>;

    fn capabilities(&self) -> DeviceCapabilities {
        match self {
            NetDevice::Virtio(d) => d.capabilities(),
            NetDevice::Ena(d) => d.capabilities(),
        }
    }

    fn receive(&mut self, t: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        match self {
            NetDevice::Virtio(d) => d
                .receive(t)
                .map(|(r, tx)| (NetRxToken::Virtio(r), NetTxToken::Virtio(tx))),
            NetDevice::Ena(d) => d
                .receive(t)
                .map(|(r, tx)| (NetRxToken::Ena(r), NetTxToken::Ena(tx))),
        }
    }

    fn transmit(&mut self, t: Instant) -> Option<Self::TxToken<'_>> {
        match self {
            NetDevice::Virtio(d) => d.transmit(t).map(NetTxToken::Virtio),
            NetDevice::Ena(d) => d.transmit(t).map(NetTxToken::Ena),
        }
    }
}

impl RxToken for NetRxToken {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        match self {
            NetRxToken::Virtio(t) => t.consume(f),
            NetRxToken::Ena(t) => t.consume(f),
        }
    }
}

impl TxToken for NetTxToken<'_> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        match self {
            NetTxToken::Virtio(t) => t.consume(len, f),
            NetTxToken::Ena(t) => t.consume(len, f),
        }
    }
}

/// Global network state — device, interface, and socket set.
pub struct NetState {
    pub sockets: SocketSet<'static>,
    pub iface: Interface,
    pub device: NetDevice,
    start_tsc: u64,
}

impl NetState {
    /// Poll the smoltcp interface — processes incoming/outgoing packets.
    pub fn poll(&mut self) {
        self.device.drain_tx();
        let now = self.now();
        self.iface.poll(now, &mut self.device, &mut self.sockets);
        socket::gc_closed_handles(self);
    }

    fn now(&self) -> Instant {
        Instant::from_millis(now_ms(self.start_tsc) as i64)
    }
}

/// Milliseconds since `start_tsc` (TSC at ~2 GHz, matching the rest of the
/// stack's coarse timebase — exact rate isn't critical for smoltcp timers).
fn now_ms(start_tsc: u64) -> u64 {
    let tsc = unsafe { core::arch::x86_64::_rdtsc() };
    tsc.wrapping_sub(start_tsc) / 2_000_000
}

static mut NET_STATE: Option<NetState> = None;
static NET_LOCK: spin::Mutex<()> = spin::Mutex::new(());

/// Initialize networking with a virtio-net PCI transport (QEMU dev path).
pub fn init_with_transport(transport: PciTransport) {
    use crate::drivers::virtio::hal::TynHal;
    use smoltcp::wire::{IpAddress, IpCidr};
    use virtio_drivers::device::net::VirtIONet;

    const QUEUE_SIZE: usize = 64;
    const BUF_LEN: usize = 2048;

    let net = VirtIONet::<TynHal, _, QUEUE_SIZE>::new(transport, BUF_LEN)
        .expect("VirtIONet::new failed");
    let vdev = VirtioNetDevice::new(net);
    let mac = vdev.mac_address();
    serial_println!("[net] virtio-net MAC={:02x?}", mac);

    let mut device = NetDevice::Virtio(vdev);
    let mut iface = interface::build(&mut device, mac);
    iface.update_ip_addrs(|addrs| {
        addrs
            .push(IpCidr::new(IpAddress::Ipv4(interface::KERNEL_IP), interface::PREFIX_LEN))
            .expect("adding kernel IP failed");
    });
    iface
        .routes_mut()
        .add_default_ipv4_route(interface::GATEWAY_IP)
        .expect("adding default route failed");

    let sockets = SocketSet::new(alloc::vec::Vec::new());
    let start_tsc = unsafe { core::arch::x86_64::_rdtsc() };
    unsafe {
        NET_STATE = Some(NetState { sockets, iface, device, start_tsc });
    }
    serial_println!("[net] initialized (virtio), IP={}", interface::KERNEL_IP);
}

/// Initialize networking with an ENA device (AWS Nitro). Runs a DHCP client
/// to obtain the VPC address before handing off to the socket layer. The
/// DHCP exchange also exercises the RX path (the OFFER/ACK are unicast to
/// our MAC).
pub fn init_with_ena(dev: EnaDevice) {
    use smoltcp::socket::dhcpv4;
    use smoltcp::wire::IpCidr;

    let mac = dev.mac_address();
    let mut device = NetDevice::Ena(dev);
    let mut iface = interface::build(&mut device, mac);

    let start_tsc = unsafe { core::arch::x86_64::_rdtsc() };
    let mut sockets = SocketSet::new(alloc::vec::Vec::new());
    let dhcp_handle = sockets.add(dhcpv4::Socket::new());

    serial_println!("[net] ENA up, starting DHCP...");
    let mut configured = false;
    loop {
        let elapsed = now_ms(start_tsc);
        let now = Instant::from_millis(elapsed as i64);
        iface.poll(now, &mut device, &mut sockets);

        match sockets.get_mut::<dhcpv4::Socket>(dhcp_handle).poll() {
            Some(dhcpv4::Event::Configured(config)) => {
                serial_println!(
                    "[net] DHCP configured: ip={} router={:?}",
                    config.address, config.router);
                iface.update_ip_addrs(|addrs| {
                    addrs.clear();
                    let _ = addrs.push(IpCidr::Ipv4(config.address));
                });
                if let Some(router) = config.router {
                    let _ = iface.routes_mut().add_default_ipv4_route(router);
                }
                configured = true;
                break;
            }
            Some(dhcpv4::Event::Deconfigured) => {}
            None => {}
        }

        if elapsed > 20_000 {
            serial_println!("[net] DHCP timed out after 20s — networking not configured");
            break;
        }
        core::hint::spin_loop();
    }

    // Drop the DHCP socket; the app uses its own sockets.
    sockets.remove(dhcp_handle);

    unsafe {
        NET_STATE = Some(NetState { sockets, iface, device, start_tsc });
    }
    if configured {
        serial_println!("[net] initialized (ENA) via DHCP");
    }
}

/// Access the global network state (SMP-safe via spinlock).
pub fn with_net<F, R>(f: F) -> R
where
    F: FnOnce(&mut NetState) -> R,
{
    let _lock = NET_LOCK.lock();
    unsafe {
        match NET_STATE.as_mut() {
            Some(state) => f(state),
            None => panic!("net not initialized"),
        }
    }
}

/// Poll the network stack (SMP-safe via spinlock).
pub fn poll() {
    let _lock = NET_LOCK.lock();
    unsafe {
        if let Some(state) = NET_STATE.as_mut() {
            state.poll();
        }
    }
}

/// Check if networking is initialized.
pub fn is_initialized() -> bool {
    unsafe { NET_STATE.is_some() }
}
