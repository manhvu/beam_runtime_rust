#!/bin/bash
# Reproducibly build Tyn's static-musl BeamAsm beam.smp via Docker/Alpine and
# extract it. See Dockerfile for the pinned inputs.
#
#   ./build-beam.sh                       # baseline: no static NIFs -> ./beam.smp
#   ./build-beam.sh -o out.smp            # choose output path
#   ./build-beam.sh --nif-modules tyn_nif # spike: compile+link nifs/tyn_nif.c
#
# --nif-modules takes space-separated NIF module names; each nifs/<name>.c is
# compiled with -DSTATIC_ERLANG_NIF and linked via --enable-static-nifs.
set -euo pipefail

DIR=$(cd "$(dirname "$0")"; pwd)
OUT="$DIR/beam.smp"
NIF_MODULES=""
DOCKER=${DOCKER:-"sudo docker"}
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out) OUT="$2"; shift 2;;
    --nif-modules) NIF_MODULES="$2"; shift 2;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done

mkdir -p "$DIR/nifs"   # ensure COPY target exists even when empty

echo "=== docker build (NIF_MODULES='${NIF_MODULES}') ==="
$DOCKER build -t tyn-beam \
  --build-arg NIF_MODULES="${NIF_MODULES}" \
  "$DIR"

cid=$($DOCKER create tyn-beam)
$DOCKER cp "$cid:/out/beam.smp" "$OUT"
$DOCKER cp "$cid:/out/beam.smp.full" "$OUT.full" 2>/dev/null || true
$DOCKER rm "$cid" >/dev/null
echo "=== beam.smp -> $OUT ($(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT") bytes, stripped) ==="
