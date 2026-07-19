#!/usr/bin/env bash
# Tyn capability suite — Layer 1: behavior, not status.
#
#   tests/run.sh <instance-ip> [port]
#
# Asserts observable CONTENT (bytes/size/effect), never just the status code —
# the sendfile bug served a truncated 231-byte body as `200 content-length:125737`
# and passed every status check for weeks. Every asset check here is byte-exact.
#
# The instance MUST be a clean-clone build: stock `mix phx.new` app, STOCK deps
# (no thousand_island/OTP patch), packed by tyn-pack. See tests/setup-test-app.sh.
#
# Exit code: 0 if all PASS, 1 if any FAIL (gates a build).
set -uo pipefail

IP="${1:?usage: tests/run.sh <instance-ip> [port]}"
PORT="${2:-8080}"
B="http://${IP}:${PORT}"
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${DIR}/fixtures.env"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; FAIL=$((FAIL+1)); }
note() { printf '  ....  %s\n' "$1"; }

# curl helpers
code()  { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1"; }
body_size() { curl -s --max-time 60 "$1" | wc -c | tr -d ' '; }
body_md5()  { curl -s --max-time 60 "$1" | md5sum | cut -d' ' -f1; }

# assert an asset is byte-exact: right status, right size, right md5.
assert_asset() { # name url expect_size expect_md5
  local name="$1" url="$2" esz="$3" emd5="$4"
  local c s m
  c=$(code "$url"); s=$(body_size "$url"); m=$(body_md5 "$url")
  if [ "$c" = "200" ] && [ "$s" = "$esz" ] && [ "$m" = "$emd5" ]; then
    ok "$name (200, ${s}B, md5 ok)"
  else
    bad "$name" "200 / ${esz}B / ${emd5}" "${c} / ${s}B / ${m}"
  fi
}

assert_md5() { # name url expect_md5
  local m; m=$(body_md5 "$2")
  [ "$m" = "$3" ] && ok "$2 (md5 ok)" || bad "$2" "$3" "$m"
}

echo "=== Tyn capability suite (Layer 1) — ${B} ==="

echo "-- HTTP serving --"
c=$(code "$B/"); [ "$c" = "200" ] && ok "GET / -> 200" || bad "GET /" "200" "$c"
sz=$(body_size "$B/"); [ "$sz" -gt 100 ] && ok "GET / body non-trivial (${sz}B)" || bad "GET / body" ">100B" "${sz}B"

# Discover the digested asset paths from the rendered page (hash varies per build,
# but SIZE + MD5 are pinned in fixtures.env for the pinned Phoenix version).
JS=$(curl -s --max-time 10 "$B/" | grep -oE '/assets/app-[a-f0-9]+\.js' | head -1)
CSS=$(curl -s --max-time 10 "$B/" | grep -oE '/assets/app-[a-f0-9]+\.css' | head -1)
[ -n "$JS" ]  && assert_asset "GET app.js  (sendfile canary)" "$B$JS"  "$APP_JS_SIZE"  "$APP_JS_MD5"  || bad "discover app.js"  "a digested /assets/app-*.js path" "none in page"
[ -n "$CSS" ] && assert_asset "GET app.css (sendfile)"        "$B$CSS" "$APP_CSS_SIZE" "$APP_CSS_MD5" || bad "discover app.css" "a digested /assets/app-*.css path" "none in page"

# Large static asset: exercises sendfile partial-write / -EAGAIN / POLLOUT across
# MANY TX windows — the 125 KB case may not be enough on a fat window.
assert_asset "GET big.bin (1.5MB sendfile, many TX windows)" "$B$BIG_BIN_PATH" "$BIG_BIN_SIZE" "$BIG_BIN_MD5"

# 404 must be a real 404, not a truncated/garbage body.
c=$(code "$B/nonexistent-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"); [ "$c" = "404" ] && ok "GET /nonexistent -> 404" || bad "GET /nonexistent" "404" "$c"

echo "-- Send paths (varied 0..255 bodies, never all-X) --"
# Inline (Bandit's own send path), large.
assert_md5 "sz/130000 (inline large)" "$B/sz/130000" "$SZ_130000_MD5"
# Multi-send (chunked) — the writev regression; corrupts at 2048 boundaries if unfixed.
assert_md5 "chk/8192/4 (multi-send)"    "$B/chk/8192/4"    "$CHK_8192_4_MD5"
assert_md5 "chk/65536/8 (multi-send)"   "$B/chk/65536/8"   "$CHK_65536_8_MD5"
assert_md5 "chk/130000/16 (multi-send)" "$B/chk/130000/16" "$CHK_130000_16_MD5"

echo "-- Throughput (sendfile TCP window — regression guard) --"
# big.bin is 1.5 MB. With a one-segment (2048-byte) TX buffer the in-flight window
# is capped and a large sendfile crawls at ~34 KB/s (~44 s), delayed-ACK-limited.
# A 32 KiB TX buffer clears ~600 KB/s (~2.5 s). Assert well under the regression:
# < 15 s (~100 KB/s floor) catches a window regression without network-jitter flakiness.
bigtime=$(curl -s -o /dev/null -w '%{time_total}' --max-time 90 "$B$BIG_BIN_PATH")
bigkbps=$(awk "BEGIN{ if ($bigtime>0) printf \"%d\", 1500000/$bigtime/1024; else print \"?\" }" 2>/dev/null)
if awk "BEGIN{exit !($bigtime > 0 && $bigtime < 15)}"; then
  ok "big.bin throughput: ${bigtime}s (< 15s; ~${bigkbps} KB/s)"
else
  bad "big.bin throughput (TX window)" "< 15s (~100+ KB/s)" "${bigtime}s — TX buffer may have regressed to a one-segment window"
fi

echo "-- Concurrency (large-asset back-pressure is where partial-write bugs hide) --"
# Portable (bash 3.2 / macOS has no `mapfile`): collect md5s into a plain string.
conc_md5s=$(seq 1 "$CONCURRENCY" | xargs -P"$CONCURRENCY" -I{} sh -c "curl -s --max-time 60 $B$BIG_BIN_PATH | md5sum | cut -d' ' -f1")
conc_total=$(printf '%s\n' "$conc_md5s" | grep -c .)
conc_distinct=$(printf '%s\n' "$conc_md5s" | sort -u)
if [ "$conc_total" = "$CONCURRENCY" ] && [ "$conc_distinct" = "$BIG_BIN_MD5" ]; then
  ok "N=${CONCURRENCY} concurrent big.bin: all ${CONCURRENCY} identical + correct"
else
  bad "N=${CONCURRENCY} concurrent big.bin" "${CONCURRENCY}x ${BIG_BIN_MD5}" "$(printf '%s\n' "$conc_md5s" | sort | uniq -c | tr '\n' '|')"
fi

echo "-- WebSocket / LiveView --"
if python3 "${DIR}/liveview_check.py" "$IP" "$PORT"; then
  ok "interactive LiveView: WS 101 + phx_join ok + counter increments over the socket"
else
  bad "interactive LiveView" "WS 101, join ok, inc diff 0->1" "see liveview_check.py output above"
fi

echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
