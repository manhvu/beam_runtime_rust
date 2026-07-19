# Tyn test suite

Turns the capability matrix from a manual snapshot into **code that asserts behavior
every build**. Designed against the two failure modes that have actually bitten us:

- **Status ≠ correctness** — the sendfile bug served a truncated 231-byte `app.js` as
  `200 content-length: 125737` and passed every status check for weeks. Every asset
  check here is **byte-exact** (`wc -c` + md5), and prints `expected vs actual` on
  failure (`app.js: expected 125737, got 231` would have ended that in an afternoon).
- **Happy-path ≠ works** — a large asset over concurrency exercises the sendfile
  partial-write / `-EAGAIN` / `POLLOUT` path that small bodies never reach.

See `directions/TEST_SUITE.md` for the full four-layer design. This is **Layer 1**.

## Run it

```sh
tests/run.sh <instance-ip> [port]     # exit 0 = all PASS, 1 = any FAIL (gates a build)
```

Against a booted instance (Nitro for the real gate; the TCG box is unreliable and
must NOT be used — it produces false failures).

## The clean-clone guarantee

The instance under test **must** be a clean-clone build, or the suite is theater —
that is exactly how the sendfile gap hid (every asset test ran against a hand-patched
demo). `tests/setup-test-app.sh` builds it:

```sh
tests/setup-test-app.sh ~/demo          # stock phx.new + stock deps + test fixtures
# it FAILS HARD if any dependency is patched.
./tyn-pack ~/demo/_build/prod/rel/demo -o rootfs.cpio --app demo --port 8080 \
    --env SECRET_KEY_BASE=$(openssl rand -hex 40) --env PHX_SERVER=true --env PORT=8080
CPIO=rootfs.cpio ./build-disk.sh        # -> disk image -> deploy
tests/run.sh <ip>
```

The one honest subtlety: the suite adds **app-level** fixtures (a controller, a
LiveView, a 1.5 MB `big.bin`) to an otherwise-stock app, but **never patches a
dependency**. The thing that was patched (thousand_island's `sendfile`) stays stock,
so a green run proves the *kernel* serves sendfile — not a dependency workaround.

## Fixtures

`fixtures.env` pins expected sizes + md5s for the pinned Phoenix version. Regenerate
after a stock build with `tests/setup-test-app.sh --print-fixtures`.

## What Layer 1 asserts

- `GET /` 200 + non-trivial body
- `app.js` / `app.css` **byte-exact** (the sendfile canary)
- `big.bin` (1.5 MB) **byte-exact** — sendfile across many TX windows
- `/nonexistent` → real 404 (not a garbage body)
- `/sz/130000` inline **byte-exact**; `/chk/{8192,65536,130000}` multi-send **byte-exact**
- N=25 concurrent `big.bin` — all identical + correct (concurrency × sendfile back-pressure)
- Interactive LiveView (`liveview_check.py`): WS 101 → `phx_join` ok → `inc` → counter
  `0→1` over the socket. This transitively proves app.js loaded and ran — a second
  independent catch for the sendfile class. (Not a headless browser; see TEST_SUITE.md.)

## Not yet built (Layers 2–4)

Regression/load numbers on real hardware, boot-reliability sweep per build, the
hours-long soak (DHCP-lease renewal, memory drift), and the long-tail third-party-app
probes. See `directions/TEST_SUITE.md`.
