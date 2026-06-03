#![no_std]
#![no_main]

extern crate alloc;

mod boot;

use core::panic::PanicInfo;
use tyn_kernel::serial_println;
use virtio_drivers::transport::pci::bus::{Command, PciRoot};
use virtio_drivers::transport::pci::{PciTransport, virtio_device_type};
use virtio_drivers::transport::{DeviceType, Transport};

#[unsafe(no_mangle)]
extern "C" fn main(_mbi: *const u8) -> ! {
    serial_println!("=== Tyn Kernel v{} ===", env!("CARGO_PKG_VERSION"));

    tyn_kernel::memory::heap::init_static();
    tyn_kernel::drivers::virtio::hal::init_dma();
    tyn_kernel::interrupts::init_idt();

    // Clear CR0.TS (Task Switched) to allow SSE instructions in user code.
    // SAFETY: Clearing TS only affects FPU/SSE lazy state saving.
    unsafe {
        core::arch::asm!("clts", options(nomem, nostack));
    }

    // NOTE: CR4.TSD can't trap RDTSC in ring 0 (we run everything in ring 0).
    // The ERTS time-backwards issue from timer preemption needs a different fix.

    // Calibrate TSC frequency against PIT (before APIC takes over PIT)
    tyn_kernel::syscall::calibrate_tsc();

    // Discover CPUs via ACPI MADT and initialize APIC
    let acpi_info = tyn_kernel::acpi::discover_cpus();
    if let Some(ref info) = acpi_info {
        serial_println!("[boot] {} CPUs available", info.num_cpus);
        let ioapic_addr = info.ioapic.as_ref().map(|io| io.address);
        tyn_kernel::apic::init_bsp(info.local_apic_addr, ioapic_addr);
    }

    // Initialize SMP scheduler
    let ncpus = acpi_info.as_ref().map(|i| i.num_cpus).unwrap_or(1);
    tyn_kernel::sched::init(ncpus);

    // Boot Application Processors (if multi-CPU)
    // Disable interrupts during AP bringup to prevent heap allocator races
    if let Some(ref info) = acpi_info {
        x86_64::instructions::interrupts::disable();
        tyn_kernel::smp::boot_aps(info);
        x86_64::instructions::interrupts::enable();
    }

    // Initialize NIC via PCI enumeration (virtio-net on QEMU, ENA on Nitro).
    // Use port-IO CF8/CFC for config access (portable across QEMU q35
    // and AWS Nitro). MCFG-discovery isn't required for Phase 1.
    init_networking();

    // Initialize in-memory VFS (cpio archive with OTP files)
    tyn_kernel::vfs::init();

    // Set up syscall entry point
    tyn_kernel::syscall::init();

    // Timer starts at first clone (sys_clone sets timer_active, calls init_timer).
    // Pre-clone init must run without interrupts — timer interferes with spin-waits.

    // Load and run embedded ELF binary
    // Use beam.smp for ERTS, hello.elf for testing
    static HELLO_ELF: &[u8] = include_bytes!("beam.smp.elf");
    serial_println!("[boot] ELF binary: {} bytes", HELLO_ELF.len());

    // The kernel's .rodata contains the embedded ELF and cpio archive.
    // Kernel at 240 MiB extends to ~291 MiB with current ELF (8.4 MB) +
    // cpio (~45 MB w/ Phoenix). Copy buffers must be above kernel's end
    // and below MMAP_NEXT base (now 0x1A00_0000 = 416 MiB).
    const ELF_COPY_BASE: usize = 0x1400_0000;            // 320 MiB
    // CPIO must sit above the ELF source buffer. Previously +10 MiB, but
    // the JIT-enabled beam.smp is ~10.1 MiB unstripped — it spilled into
    // the cpio region and clobbered the tail of the RW segment (including
    // the initialized `_dl_ns` pointer used by musl's __libc_setup_tls,
    // crashing JIT boots with #GP at 0x99cae4 / r14 = garbage). 16 MiB
    // gives headroom for any plausible BEAM build.
    const CPIO_COPY_BASE: usize = ELF_COPY_BASE + 0x100_0000; // +16 MiB = 336 MiB
    assert!(HELLO_ELF.len() <= CPIO_COPY_BASE - ELF_COPY_BASE,
        "embedded ELF would overlap CPIO buffer — bump CPIO_COPY_BASE");
    // SAFETY: Destination regions are identity-mapped and above the kernel.
    let elf_copy = unsafe {
        let dst = ELF_COPY_BASE as *mut u8;
        core::ptr::copy_nonoverlapping(HELLO_ELF.as_ptr(), dst, HELLO_ELF.len());
        core::slice::from_raw_parts(dst, HELLO_ELF.len())
    };
    // Copy cpio to safe location and update the VFS to use it.
    unsafe {
        tyn_kernel::vfs::relocate(CPIO_COPY_BASE);
    }
    serial_println!("[boot] ELF copied to {:#x}, CPIO to {:#x}", ELF_COPY_BASE, CPIO_COPY_BASE);

    // SAFETY: Target addresses (0x400000+) are identity-mapped and writable.
    // Source data is at 32 MiB, safely above the load addresses.
    let info = unsafe { tyn_kernel::elf::load(elf_copy) }.expect("ELF load failed");
    serial_println!("[boot] ELF mem_end={:#x}", info.mem_end);

    // Set initial brk above the loaded ELF segments
    tyn_kernel::syscall::set_initial_brk(info.mem_end);

    // Allocate a user stack (2 MiB, within the 256M RAM region)
    const USER_STACK_BASE: u64 = 0x0E00_0000; // 224 MiB
    const USER_STACK_SIZE: u64 = 2 * 1024 * 1024;
    let user_stack_top = USER_STACK_BASE + USER_STACK_SIZE;
    serial_println!("[boot] zeroing stack at {:#x}..{:#x}", USER_STACK_BASE, user_stack_top);
    // SAFETY: Stack range is identity-mapped and unused.
    unsafe {
        core::ptr::write_bytes(USER_STACK_BASE as *mut u8, 0, USER_STACK_SIZE as usize);
    }
    serial_println!("[boot] stack zeroed");

    // Build initial stack for musl CRT.
    // musl _start expects: [rsp]=argc, [rsp+8..]=argv ptrs, NULL, envp ptrs, NULL, auxv
    let mut sp = user_stack_top;
    // SAFETY: Writing to identity-mapped stack memory.
    unsafe {
        // Put argv strings near top of stack
        let args: &[&[u8]] = &[
            b"/otp/erts-15.2.7/bin/beam.smp\0",
            b"-S\0", b"2:2\0",
            b"-A\0", b"1\0",
            // Raise ERTS process and port limits. Defaults can be as
            // low as 256 (+Q) in some minimal builds; with ~50 ports
            // used at boot this caps usable connections to ~200. Each
            // gen_tcp:accept allocates a port; Bandit spawns a process
            // per connection — both need headroom for sustained load.
            // (beam.smp accepts only `-`-prefixed flags directly; the
            // `+P` / `+Q` form is the erlexec convention. See
            // erts/emulator/beam/erl_init.c line ~1349 — the parser
            // calls erts_usage() and exits on any non-`-` argv[i].)
            // See directions/STRESS_TEST.md for the 200-wall finding.
            b"-P\0", b"65536\0",
            b"-Q\0", b"65536\0",
            b"--\0",
            b"-root\0", b"/otp\0",
            b"-bindir\0", b"/otp/erts-15.2.7/bin\0",
            b"-noshell\0",
            b"-noinput\0",
            b"-kernel\0", b"inet_backend\0", b"inet\0",
            // Bisection probe: does proc_lib:spawn work? does
            // gen_server:start_link work? Each stage prints before AND
            // after so we can see exactly which step stalls.
            // §B2.15: ThousandIsland with my_handler — a stripped-down
            // pure-Erlang gen_server that mimics TI.Handler's exact init
            // shape (Process.flag(:trap_exit, true), then waits for
            // {:thousand_island_ready, ...} in handle_info) but DOESN'T
            // use the `use ThousandIsland.Handler` macro.
            // §B2.16 probe: install a custom logger handler (crash_logger)
            // BEFORE starting ThousandIsland, so any crash in any
            // GenServer / supervisor chain prints to serial. TI's
            // Acceptor crashes silently after curl connects — we know
            // because the handler module is never even loaded — so this
            // catches whatever exception is being silently swallowed.
            // §B2.17 probe: replicate TI's listen options exactly, accept
            // the connection ourselves, and print exactly what gen_tcp
            // returns. This isolates whether the bug is in gen_tcp:accept
            // or in something TI does after.
            // §B2.18 probe: same TI options, but accept from inside a
            // Task (proc_lib-spawned, like TI's Acceptor) instead of the
            // main eval shell. If THIS fails but the main-shell version
            // passed, the bug is process-context dependent.
            // §B2.18 probe: cross-process accept. P1 (gen_server-like
            // process via Task) creates listen socket. P1 sends socket
            // to P2 (another Task) via message. P2 calls
            // gen_tcp:accept(L). This matches TI's Listener→Acceptor
            // socket ownership transfer.
            // §B2.19 probe: spawn 100 acceptor tasks all blocked on
            // gen_tcp:accept on the SAME listener socket. This matches
            // TI's default num_acceptors=100. When curl connects, only
            // one should wake — but if our kernel mishandles concurrent
            // accept-waiters, we'll see the failure mode here.
            // §B2.20 probe: bisect concurrent-accept-waiter count.
            // 1 worked. 100 didn't. Try 2.
            // Manual gen_tcp HTTP demo. Bandit/ThousandIsland themselves
            // stall on Tyn — see MESSAGE_DELIVERY.md §B2.16-§B2.20.
            // The bug isolated to concurrent gen_tcp:accept waiters: TI
            // spawns 100 acceptors by default and our kernel doesn't
            // deliver an incoming connection to any of them. With 1
            // waiter the kernel's accept-completion path works; with N
            // it doesn't. Likely fix is in src/net/socket.rs around
            // how inet_async accept replies are routed.
            // Every primitive (listen / accept / setopts({active,once}) /
            // controlling_process / active-mode {tcp,S,Data} delivery /
            // send / close) works in this raw flow. Curl returns "Hi".
            // §B2.21 verify-fix: same 100-acceptor stress test that
            // demonstrated the bug. After fixing sys_accept's race
            // (atomic check-and-swap inside with_net) and wiring up
            // fcntl(F_SETFL, O_NONBLOCK) for sockets, exactly one of
            // the 100 should wake on curl.
            // §B2.21 final verify: TI w/ ORIGINAL Connection.beam +
            // EchoHandler. With kernel-side accept race fixed, this
            // should now actually work end-to-end.
            // §B2.22: Bandit + HelloPlug (Elixir). With the kernel-side
            // sys_accept fix in place, Bandit's TI-based dispatch chain
            // should now work end-to-end. Both Bandit and HelloPlug were
            // compiled May 5 (before our kernel fix) but their bytecode
            // is unchanged — only the kernel's accept semantics changed.
            // §B3 Phoenix bisection #1: Bandit with Router directly (skip Endpoint middleware)
            b"-eval\0", b"application:ensure_all_started(telemetry), application:ensure_all_started(jason), {ok,_}='Elixir.Bandit':start_link([{plug,bench_plug},{port,8080},{scheme,http}]), tcp_shell:start(9090), serial_shell:start(), io:format(\"phoenix_listening~n\"), io:format(\"shell_listening 9090~n\"), io:format(\"serial_shell ready~n\"), receive _ -> ok after 1800000 -> ok end.\0",
        ];
        let mut arg_ptrs = [0u64; 24];
        for (i, arg) in args.iter().enumerate() {
            sp -= 2048; // must fit longest arg (diagnostic eval strings can be 1500+ bytes)
            core::ptr::copy_nonoverlapping(arg.as_ptr(), sp as *mut u8, arg.len());
            arg_ptrs[i] = sp;
        }
        let argc = args.len();

        // Put environment variables
        let envs: &[&[u8]] = &[
            b"ROOTDIR=/otp\0",
            b"BINDIR=/otp/erts-15.2.7/bin\0",
            b"EMU=beam\0",
            b"PROGNAME=beam.smp\0",
        ];
        let mut env_ptrs = [0u64; 8];
        for (i, env) in envs.iter().enumerate() {
            sp -= 256;
            core::ptr::copy_nonoverlapping(env.as_ptr(), sp as *mut u8, env.len());
            env_ptrs[i] = sp;
        }
        let envc = envs.len();

        // 16 bytes of pseudo-random data for AT_RANDOM (musl stack canary)
        sp -= 16;
        let at_random_ptr = sp;
        let mut tsc = core::arch::x86_64::_rdtsc();
        for i in 0..16u64 {
            *(sp.wrapping_add(i) as *mut u8) = tsc as u8;
            tsc = tsc.wrapping_mul(6364136223846793005).wrapping_add(1);
        }

        // Align to 16 bytes
        sp &= !0xF;

        // Build stack frame (grows down):
        // AT_NULL
        sp -= 16;
        *(sp as *mut u64) = 0;
        *((sp + 8) as *mut u64) = 0;

        // AT_RANDOM (25) — pointer to 16 random bytes
        sp -= 16;
        *(sp as *mut u64) = 25;
        *((sp + 8) as *mut u64) = at_random_ptr;

        // AT_ENTRY (9) — entry point of the program
        sp -= 16;
        *(sp as *mut u64) = 9;
        *((sp + 8) as *mut u64) = info.entry;

        // AT_PHNUM (5) — number of program headers
        sp -= 16;
        *(sp as *mut u64) = 5;
        *((sp + 8) as *mut u64) = info.phnum as u64;

        // AT_PHENT (4) — size of each program header entry
        sp -= 16;
        *(sp as *mut u64) = 4;
        *((sp + 8) as *mut u64) = info.phentsize as u64;

        // AT_PHDR (3) — address of program headers in memory
        sp -= 16;
        *(sp as *mut u64) = 3;
        *((sp + 8) as *mut u64) = info.phdr_vaddr;

        // AT_PAGESZ (6)
        sp -= 16;
        *(sp as *mut u64) = 6;
        *((sp + 8) as *mut u64) = 4096;

        // AT_BASE (7) — load bias of the interpreter (0 for static).
        sp -= 16;
        *(sp as *mut u64) = 7;
        *((sp + 8) as *mut u64) = 0;

        // AT_HWCAP (16) — hardware capability bitmask. musl on x86_64
        // detects features via CPUID directly so 0 is acceptable.
        sp -= 16;
        *(sp as *mut u64) = 16;
        *((sp + 8) as *mut u64) = 0;

        // AT_CLKTCK (17) — clock ticks per second.
        sp -= 16;
        *(sp as *mut u64) = 17;
        *((sp + 8) as *mut u64) = 100;

        // envp NULL terminator
        sp -= 8;
        *(sp as *mut u64) = 0;

        // envp pointers (in reverse order)
        for i in (0..envc).rev() {
            sp -= 8;
            *(sp as *mut u64) = env_ptrs[i];
        }

        // argv NULL terminator
        sp -= 8;
        *(sp as *mut u64) = 0;

        // argv pointers (in reverse order since stack grows down)
        for i in (0..argc).rev() {
            sp -= 8;
            *(sp as *mut u64) = arg_ptrs[i];
        }

        // argc
        sp -= 8;
        *(sp as *mut u64) = argc as u64;
    }

    serial_println!("[boot] launching ERTS at {:#x} sp={:#x}", info.entry, sp);
    tyn_kernel::syscall::jump_to_user(info.entry, sp);
}

/// Enumerate PCI bus and initialize a NIC if found.
/// Prefers virtio-net (used on QEMU). Falls back to logging an ENA
/// device when running on AWS Nitro — Phase 1 of ENA support only
/// probes and reads version registers (see directions/ENA_DRIVER.md
/// for the full plan); Phase 2 wires it into smoltcp.
fn init_networking() {
    use virtio_drivers::transport::pci::bus::BarInfo;

    serial_println!("[pci] using port-IO config (CF8/CFC)");
    let mut root = PciRoot::new(tyn_kernel::net::pci_io::PortIoCam::new());

    // Walk all 256 PCI buses. Port-IO returns 0xFFFFFFFF for unmapped
    // slots (the standard sentinel), so we only see real devices —
    // no ghost devices from reading past an ECAM window.
    let mut devices: alloc::vec::Vec<_> = alloc::vec::Vec::new();
    let mut total = 0usize;
    let mut ghost = 0usize;
    for bus in 0u8..=255u8 {
        for (dev_fn, info) in root.enumerate_bus(bus) {
            total += 1;
            // Filter unmapped slots: 0xFFFF is the PCI standard, 0x0000
            // is what Nitro returns. Anything else we keep.
            if info.vendor_id == 0x0000 || info.vendor_id == 0xFFFF {
                continue;
            }
            // Real PCI devices we drive (virtio or ENA) live on bus 0
            // on every platform we target. Treat anything past bus 0
            // with an unrecognized vendor as a ghost from the bus-range
            // extending past the actual ECAM, and drop it silently to
            // keep the serial log readable on AWS Nitro.
            let recognised = virtio_device_type(&info).is_some()
                || tyn_kernel::net::ena::is_ena(info.vendor_id, info.device_id);
            if dev_fn.bus > 0 && !recognised {
                ghost += 1;
                continue;
            }
            devices.push((dev_fn, info));
        }
        if bus == 255 { break; }
    }
    serial_println!("[pci] scanned {} function slots, {} ghost, {} usable",
        total, ghost, devices.len());
    for (dev_fn, info) in &devices {
        serial_println!("[pci]   {:02x}:{:02x}.{} {:04x}:{:04x} class={:02x}.{:02x}",
            dev_fn.bus, dev_fn.device, dev_fn.function,
            info.vendor_id, info.device_id, info.class, info.subclass);
    }

    // First pass: virtio-net (QEMU / KVM dev path).
    for (dev_fn, info) in &devices {
        if let Some(vtype) = virtio_device_type(info) {
            serial_println!("[pci] {}:{}.{} VirtIO {:?}",
                dev_fn.bus, dev_fn.device, dev_fn.function, vtype);
            root.set_command(
                *dev_fn,
                Command::IO_SPACE | Command::MEMORY_SPACE | Command::BUS_MASTER,
            );

            let transport =
                PciTransport::new::<tyn_kernel::drivers::virtio::hal::TynHal, _>(&mut root, *dev_fn)
                    .expect("PciTransport::new failed");

            if transport.device_type() == DeviceType::Network {
                tyn_kernel::net::init_with_transport(transport);
                return;
            }
        }
    }

    // Second pass: AWS ENA (Nitro). Identified by vendor 0x1d0f.
    for (dev_fn, info) in &devices {
        if !tyn_kernel::net::ena::is_ena(info.vendor_id, info.device_id) {
            continue;
        }
        serial_println!(
            "[pci] {}:{}.{} ENA {:04x}:{:04x}",
            dev_fn.bus, dev_fn.device, dev_fn.function, info.vendor_id, info.device_id);
        root.set_command(
            *dev_fn,
            Command::MEMORY_SPACE | Command::BUS_MASTER,
        );
        let bars = root.bars(*dev_fn).expect("ENA bars()");
        let bar0 = match bars[0] {
            Some(BarInfo::Memory { address, .. }) => address,
            _ => {
                serial_println!("[ena] BAR0 is not a memory BAR; skipping");
                continue;
            }
        };
        tyn_kernel::net::ena::probe(
            bar0,
            info.device_id,
            (dev_fn.bus, dev_fn.device, dev_fn.function));
        // Phase 2B: admin queue + I/O queues + smoltcp (DHCP). On success the
        // global NetState is initialized and networking is live.
        if tyn_kernel::net::ena::init(bar0) {
            return;
        }
    }

    serial_println!("[net] no usable NIC found (virtio-net or fully-wired ENA), networking disabled");
}

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    serial_println!("KERNEL PANIC: {}", info);
    tyn_kernel::halt_loop();
}
