#!/usr/bin/env python3
"""Assert interactive LiveView works end to end over the WebSocket.

    liveview_check.py <ip> [port]   -> exit 0 if the counter increments, else 1

This is the *second* independent catch for the sendfile class: it only passes if
app.js actually loaded and the LiveSocket connected. A raw client can't drive
LiveView unless it replicates the browser's session-cookie + CSRF + session/static
token handshake — which is exactly what this does (the missing cookie is why an
earlier hand-rolled attempt got a spurious "stale").

Not a headless browser (TEST_SUITE.md Layer 1 prefers Playwright in CI); it proves
the transport + join + event round-trip without a browser dependency. If/when a
headless browser lands, this becomes the fallback.
"""
import base64, http.cookiejar, json, os, re, socket, sys, urllib.request

ip = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
base = f"http://{ip}:{port}"


def fail(msg):
    print(f"    liveview: FAIL — {msg}", file=sys.stderr)
    sys.exit(1)


# 1. GET /counter with a cookie jar (LiveView validates CSRF against the session cookie).
cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
try:
    html = opener.open(f"{base}/counter", timeout=15).read().decode()
except Exception as e:  # noqa: BLE001
    fail(f"GET /counter failed: {e}")

cookie = "; ".join(f"{c.name}={c.value}" for c in cj)
try:
    csrf = re.search(r'csrf-token" content="([^"]+)"', html).group(1)
    sess = re.search(r'data-phx-session="([^"]+)"', html).group(1)
    stat = re.search(r'data-phx-static="([^"]+)"', html).group(1)
    pid = re.search(r'id="(phx-[^"]+)"', html).group(1)
except AttributeError:
    fail("/counter is missing LiveView markers (csrf/session/static/phx-id)")

# 2. WebSocket upgrade.
key = base64.b64encode(os.urandom(16)).decode()
req = (
    f"GET /live/websocket?_csrf_token={csrf}&vsn=2.0.0 HTTP/1.1\r\n"
    f"Host: {ip}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
    f"Origin: http://ci-check.invalid\r\nCookie: {cookie}\r\n\r\n"
)
s = socket.create_connection((ip, port), timeout=15)
s.settimeout(15)
s.sendall(req.encode())
resp = b""
while b"\r\n\r\n" not in resp:
    chunk = s.recv(1)
    if not chunk:
        fail("connection closed during WS handshake")
    resp += chunk
status = resp.split(b"\r\n", 1)[0].decode()
if "101" not in status:
    fail(f"WS upgrade not 101 (got: {status!r}) — check_origin? asset delivery?")


def send(obj):
    data = json.dumps(obj).encode()
    hdr = bytearray([0x81])
    n = len(data)
    if n < 126:
        hdr.append(0x80 | n)
    else:
        hdr += bytes([0x80 | 126, n >> 8, n & 0xFF])
    mask = os.urandom(4)
    hdr += mask
    s.sendall(bytes(hdr) + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def recv():
    s.recv(1)
    b2 = s.recv(1)[0]
    ln = b2 & 0x7F
    if ln == 126:
        ln = int.from_bytes(s.recv(2), "big")
    buf = b""
    while len(buf) < ln:
        buf += s.recv(ln - len(buf))
    return buf.decode(errors="replace")


# 3. Join the LiveView channel, then send the "inc" event.
topic = f"lv:{pid}"
send(["4", "4", topic, "phx_join", {
    "url": f"{base}/counter", "session": sess, "static": stat,
    "params": {"_csrf_token": csrf, "_mounts": 0},
}])
join = recv()
if '"status":"ok"' not in join:
    fail(f"phx_join not ok: {join[:200]}")

send(["4", "5", topic, "event", {"type": "click", "event": "inc", "value": {}}])
diff = recv()
s.close()
if '"status":"ok"' not in diff:
    fail(f"inc event not ok: {diff[:200]}")
# The stock CounterLive renders the count as dynamic "3"->"0"; after one inc it is "1".
if '"1"' not in diff:
    fail(f"inc did not increment the counter (diff: {diff[:200]})")

print("    liveview: WS 101 + join ok + counter 0->1")
sys.exit(0)
