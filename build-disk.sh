#!/bin/bash
# Build a bootable raw disk image containing GRUB + the Tyn kernel.
#
# The output is a BIOS-bootable disk that loads GRUB from the MBR, which
# in turn loads /boot/tyn-kernel via the multiboot1 protocol. This is the
# shape AWS expects for HVM AMIs imported from raw disk images (see
# directions/AMI.md for the upload/import flow).
#
# Output: $IMAGE (default /dev/shm/tyn-disk.raw). Run from any directory.
# Requires: sudo (for losetup / mkfs / mount / grub-install), grub-pc-bin,
# parted, e2fsprogs.
#
# To boot the image under QEMU (the same shape Nitro will run):
#   qemu-system-x86_64 \
#     -drive file=$IMAGE,format=raw,if=virtio \
#     -m 2560M -machine q35 -cpu host -enable-kvm -smp 2 \
#     -nographic -no-reboot -serial mon:stdio \
#     -device virtio-net-pci,netdev=net0,disable-legacy=on,disable-modern=off \
#     -netdev user,id=net0,hostfwd=tcp::5566-:8080,hostfwd=tcp::5567-:9090
#
set -e

KERNEL=${KERNEL:-target/x86_64-tyn/release/tyn-kernel}
# The cpio GRUB loads as a multiboot module. Track 1 Phase 1b: the kernel
# relocates this module out of low RAM to CPIO_HOME and zeros its staging area
# before elf::load, then serves the VFS from it (embedded copy is the fallback
# when no module is present). GRUB places the module at ~1 MiB, on top of the
# ERTS load region, so the relocate+zero is what makes it safe. Verified to boot
# to Phoenix with source=MODULE. This is the SAME file embedded in src/vfs.rs.
CPIO=${CPIO:-src/otp-rootfs.cpio}
IMAGE=${IMAGE:-/dev/shm/tyn-disk.raw}
SIZE_MB=${SIZE_MB:-128}
MOUNT=${MOUNT:-/tmp/tyn-mount}

if [ ! -f "$KERNEL" ]; then
  echo "ERROR: kernel not found at $KERNEL" >&2
  echo "Build it first with: cargo build --release --target x86_64-tyn.json -Zbuild-std=core,alloc,compiler_builtins -Zbuild-std-features=compiler-builtins-mem" >&2
  exit 1
fi

if [ ! -f "$CPIO" ]; then
  echo "ERROR: cpio module not found at $CPIO" >&2
  exit 1
fi

echo "kernel: $KERNEL ($(stat -c%s "$KERNEL" 2>/dev/null || stat -f%z "$KERNEL") bytes)"
echo "cpio:   $CPIO ($(stat -c%s "$CPIO" 2>/dev/null || stat -f%z "$CPIO") bytes)"
echo "image:  $IMAGE ($SIZE_MB MB)"

echo "=== Creating disk image ==="
dd if=/dev/zero of=$IMAGE bs=1M count=$SIZE_MB status=none

echo "=== Partitioning (msdos / ext2 / boot flag) ==="
parted $IMAGE --script -- \
  mklabel msdos \
  mkpart primary ext2 1MiB 100% \
  set 1 boot on

echo "=== Loop device ==="
LOOP=$(sudo losetup --find --show --partscan $IMAGE)
echo "loop=$LOOP"
sleep 1
PART=${LOOP}p1
if [ ! -b "$PART" ]; then
  sudo partprobe $LOOP
  sleep 1
fi
if [ ! -b "$PART" ]; then
  echo "ERROR: partition $PART not found" >&2
  sudo losetup -d $LOOP
  exit 1
fi

cleanup() {
  sudo umount $MOUNT 2>/dev/null || true
  sudo losetup -d $LOOP 2>/dev/null || true
}
trap cleanup EXIT

echo "=== mkfs ext2 ==="
sudo mkfs.ext2 -L tyn $PART > /dev/null

echo "=== Mount + install GRUB + copy kernel ==="
sudo mkdir -p $MOUNT
sudo mount $PART $MOUNT

sudo grub-install \
  --target=i386-pc \
  --boot-directory=$MOUNT/boot \
  --modules="multiboot normal part_msdos ext2 biosdisk" \
  $LOOP 2>&1 | tail -3

sudo cp $KERNEL $MOUNT/boot/tyn-kernel
sudo cp $CPIO   $MOUNT/boot/rootfs.cpio
sudo mkdir -p $MOUNT/boot/grub
sudo tee $MOUNT/boot/grub/grub.cfg > /dev/null << 'EOF'
set timeout=0
set default=0

# Tyn ships a multiboot1 header (magic 0x1BADB002 in src/multiboot.S).
# Use the `multiboot`/`module` commands, not `multiboot2`/`module2`.
# The `module` line hands the cpio to the kernel as a multiboot module; the
# kernel relocates it out of low RAM and serves the VFS from it (Phase 1b).
menuentry "Tyn" {
    multiboot /boot/tyn-kernel
    module /boot/rootfs.cpio
    boot
}
EOF

ls -la $MOUNT/boot/
trap - EXIT
cleanup
echo "=== Done ==="
ls -lh $IMAGE
