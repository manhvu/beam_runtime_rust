#!/bin/bash
set -u
cd /home/ubuntu/work
DISK=/home/ubuntu/work/disk_tmpfs.raw
LOG=/home/ubuntu/work/disc.log; rm -f "$LOG"
pkill -9 -f qemu-system 2>/dev/null; sleep 2
timeout 220 qemu-system-x86_64 -accel tcg -cpu max -m 2560M -machine q35 -smp 1 \
  -drive file="$DISK",format=raw,if=ide -no-reboot -nographic -serial "file:$LOG" \
  -device virtio-net-pci,netdev=n0,disable-legacy=on,disable-modern=off \
  -netdev "user,id=n0,hostfwd=tcp::5650-:8080" </dev/null >/dev/null 2>&1 &
QP=$!
for i in $(seq 1 120); do grep -qa "PB_END" "$LOG" 2>/dev/null && break; kill -0 $QP 2>/dev/null || break; sleep 1; done
echo "=== PB_END at ${i}s; settle 3s ==="; sleep 3

RAW () { # size
  local b="$1"; local src=/tmp/rw_${b}.bin; head -c "$b" /dev/urandom > "$src"
  local want; want=$(sha256sum "$src" | awk '{print $1}')
  local out; out=$(curl -s -o /tmp/rr.txt -w "%{http_code}" --max-time 120 \
    -H "Content-Type: application/octet-stream" --data-binary "@${src}" http://localhost:5650/raw)
  local got; got=$(awk "{print \$3}" /tmp/rr.txt); local sz; sz=$(awk "{print \$2}" /tmp/rr.txt)
  [ "$want" = "$got" ] && echo "RAW $b http=$out size=$sz BYTE_EXACT=YES" || echo "RAW $b http=$out body=[$(cat /tmp/rr.txt)]"
}
MP () { # size
  local b="$1"; local src=/tmp/mp_${b}.bin; head -c "$b" /dev/urandom > "$src"
  local want; want=$(sha256sum "$src" | awk '{print $1}')
  local out; out=$(curl -s -o /tmp/mr.txt -w "%{http_code}" --max-time 120 -F "file=@${src}" http://localhost:5650/upload)
  local got; got=$(awk "{print \$3}" /tmp/mr.txt)
  [ "$want" = "$got" ] && echo "MULTIPART $b http=$out BYTE_EXACT=YES" || echo "MULTIPART $b http=$out body=[$(cat /tmp/mr.txt)]"
}
echo "--- raw body path (no multipart, no tmpfs) ---"
RAW 262144; RAW 1048576; RAW 3145728
echo "--- multipart path (tmpfs) ---"
MP 262144; MP 1048576
kill -9 $QP 2>/dev/null; pkill -9 -f qemu-system 2>/dev/null
echo "=== done ==="
