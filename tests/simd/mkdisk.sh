#!/bin/bash
# Build a BIOS/GRUB-bootable raw disk from a Tyn kernel + a cpio module.
#   mkdisk.sh <cpio> <image>     KERNEL=<kernel-elf> (env, default = repo release build)
# Tracked test helper so the SIMD-preemption suite (drive_simd.sh) is buildable from
# a clean clone — do NOT depend on an uncommitted host scratch copy.
# Requires: sudo (losetup/mkfs/mount/grub-install), parted, grub-pc-bin, e2fsprogs.
set -e
KERNEL="${KERNEL:-target/x86_64-tyn/release/tyn-kernel}"; CPIO="$1"; IMAGE="$2"; SIZE_MB=128; MOUNT=/tmp/tyn-mount-$$
dd if=/dev/zero of="$IMAGE" bs=1M count=$SIZE_MB status=none
parted "$IMAGE" --script -- mklabel msdos mkpart primary ext2 1MiB 100% set 1 boot on
LOOP=$(sudo losetup --find --show --partscan "$IMAGE"); PART=${LOOP}p1
[ -b "$PART" ] || { sudo partprobe "$LOOP"; sleep 1; }
sudo mkfs.ext2 -L tyn "$PART" >/dev/null; sudo mkdir -p "$MOUNT"; sudo mount "$PART" "$MOUNT"
sudo grub-install --target=i386-pc --boot-directory="$MOUNT/boot" --modules="multiboot normal part_msdos ext2 biosdisk" "$LOOP" 2>&1 | tail -1
sudo cp "$KERNEL" "$MOUNT/boot/tyn-kernel"; sudo mkdir -p "$MOUNT/boot/grub"
sudo cp "$CPIO" "$MOUNT/boot/rootfs.cpio"; printf 'set timeout=0\nset default=0\nmenuentry "Tyn" {\n  multiboot /boot/tyn-kernel\n  module /boot/rootfs.cpio\n  boot\n}\n' | sudo tee "$MOUNT/boot/grub/grub.cfg" >/dev/null
sync; sudo umount "$MOUNT"; sudo losetup -d "$LOOP"; sudo rmdir "$MOUNT"; echo built
