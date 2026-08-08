#!/bin/bash
# Boot a tmpfs-probe disk in QEMU, run the PB self-test, then drive real HTTP
# multipart uploads and assert each is sha256 byte-exact. Env overrides:
#   DISK  path to disk image        (default /home/ubuntu/work/disk_tmpfs.raw)
#   HPORT host port fwd -> guest 8080 (default 5620)
set -u
DISK="${DISK:-/home/ubuntu/work/disk_tmpfs.raw}"
HPORT="${HPORT:-5620}"
LOG="$(dirname "$DISK")/tmpfs_up.log"; rm -f "$LOG"
pkill -9 -f qemu-system 2>/dev/null; sleep 2
timeout 260 qemu-system-x86_64 -accel tcg -cpu max -m 2560M -machine q35 -smp 1 \
  -drive file="$DISK",format=raw,if=ide -no-reboot -nographic -serial "file:$LOG" \
  -device virtio-net-pci,netdev=n0,disable-legacy=on,disable-modern=off \
  -netdev "user,id=n0,hostfwd=tcp::${HPORT}-:8080" </dev/null >/dev/null 2>&1 &
QP=$!
# Wait for the app to start its listener (self-test PB_END also confirms boot done)
for i in $(seq 1 200); do
  grep -qa "PB_END\|phoenix_listening\|tyn_boot: started" "$LOG" 2>/dev/null && { break; }
  kill -0 $QP 2>/dev/null || break
  sleep 1
done
echo "=== boot marker at ${i}s ==="; sleep 4
# health check
echo "--- /health ---"; curl -s --max-time 10 http://localhost:${HPORT}/health; echo

run_upload () {
  local name="$1" bytes="$2"
  local src=/tmp/up_${name}.bin
  head -c "$bytes" /dev/urandom > "$src"
  local want; want=$(sha256sum "$src" | awk '{print $1}')
  local resp; resp=$(curl -s --max-time 30 -F "file=@${src}" http://localhost:${HPORT}/upload)
  local got; got=$(echo "$resp" | awk '{print $3}')
  local gotsize; gotsize=$(echo "$resp" | awk '{print $2}')
  if [ "$want" = "$got" ] && [ "$bytes" = "$gotsize" ]; then
    echo "UPLOAD $name bytes=$bytes BYTE_EXACT=YES"
  else
    echo "UPLOAD $name bytes=$bytes BYTE_EXACT=NO want=$want got=$got gotsize=$gotsize resp=[$resp]"
  fi
}

echo "=== single small (4 KiB) ==="; run_upload small 4096
echo "=== single large (3 MiB, > CAP-adjacent, multi-buffer) ==="; run_upload large 3145728
echo "=== 6 concurrent (128 KiB each), all hash-checked ==="
for j in 1 2 3 4 5 6; do ( run_upload conc$j 131072 ) & done; wait

kill -9 $QP 2>/dev/null; pkill -9 -f qemu-system 2>/dev/null
echo "=== app-side self-test (PB) ==="
grep -aE "PB_BEGIN|PB |PB_END|\[tmpfs\]" "$LOG" | tr -d "\000"
echo "=== done ==="
