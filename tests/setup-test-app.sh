#!/usr/bin/env bash
# Build the clean-clone test app: a STOCK `mix phx.new` Phoenix app with STOCK
# deps (no thousand_island/OTP patch — the patch that hid the sendfile gap), plus
# app-level test fixtures (a large static asset + multi-send routes + CounterLive).
#
#   tests/setup-test-app.sh [dest_dir]        # build the release
#   tests/setup-test-app.sh --print-fixtures  # print sizes/md5s for fixtures.env
#
# The distinction that matters: we add APP code (a controller, a LiveView, a static
# file) but NEVER touch a dependency. That is the honest clean-clone guarantee — the
# thing that was patched (thousand_island's sendfile) stays stock, so a green run
# proves the KERNEL serves sendfile, not a dependency workaround.
#
# Output: $DEST/_build/prod/rel/<app>  (feed to tyn-pack, then build-disk.sh).
set -euo pipefail

PHX_NEW_VERSION=1.7.14   # resolves Phoenix ~> 1.7.24; asset md5s pinned in fixtures.env
APP=demo
DEST="${1:-$HOME/${APP}}"

gen_big_bin() { # path size  — deterministic 0..255 pattern (varied, never all-X)
  python3 -c "import sys;n=int(sys.argv[2]);sys.stdout.buffer.write((bytes(range(256))*(n//256+1))[:n])" "$1" "$2"
}

if [ "${1:-}" = "--print-fixtures" ]; then
  # Recompute expected values from a stock build's artifacts (run after a build).
  R="$DEST/_build/prod/rel/$APP/lib"
  JS=$(ls "$R"/${APP}-*/priv/static/assets/app-*.js  | grep -v '\.gz$' | head -1)
  CSS=$(ls "$R"/${APP}-*/priv/static/assets/app-*.css | grep -v '\.gz$' | head -1)
  echo "APP_JS_SIZE=$(wc -c <"$JS" | tr -d ' ')  APP_JS_MD5=$(md5sum "$JS" | cut -d' ' -f1)"
  echo "APP_CSS_SIZE=$(wc -c <"$CSS" | tr -d ' ')  APP_CSS_MD5=$(md5sum "$CSS" | cut -d' ' -f1)"
  tmp=$(mktemp); gen_big_bin "$tmp" 1500000
  echo "BIG_BIN_SIZE=1500000  BIG_BIN_MD5=$(md5sum "$tmp" | cut -d' ' -f1)"; rm -f "$tmp"
  exit 0
fi

echo "=== stock phx.new ${APP} (phx_new ${PHX_NEW_VERSION}) at ${DEST} ==="
export MIX_ENV=prod
rm -rf "$DEST"
mix archive.install hex phx_new "$PHX_NEW_VERSION" --force >/dev/null 2>&1
( cd "$(dirname "$DEST")" && yes | mix phx.new "$(basename "$DEST")" --no-ecto --no-mailer --no-dashboard )
cd "$DEST"
mix deps.get

echo "=== assert deps are STOCK (no bridge / sendfile patch anywhere) ==="
if grep -rq "tyn_chunk\|OTP only falls back" deps/ 2>/dev/null; then
  echo "FATAL: a dependency is patched — this is NOT a clean clone" >&2; exit 1
fi
echo "  ok: deps/thousand_island uses stock :file.sendfile"

echo "=== add APP-level test fixtures (controller + LiveView + big.bin) ==="
cat > lib/${APP}_web/controllers/tyn_test_controller.ex <<'EX'
defmodule DemoWeb.TynTestController do
  @moduledoc "Test-only routes for the Tyn capability suite (multi-send + inline)."
  use DemoWeb, :controller

  # first n bytes of the 0..255 pattern — varied content so hashes catch
  # reordering/duplication (an all-X body cannot).
  defp vbody(n),
    do: :binary.part(:binary.copy(:binary.list_to_bin(Enum.to_list(0..255)), div(n, 256) + 1), 0, n)

  # inline single send_resp (Bandit's own send path)
  def sz(conn, %{"n" => n}), do: send_resp(conn, 200, vbody(String.to_integer(n)))

  # chunked = k multi-sends on one socket (the writev regression path)
  def chk(conn, %{"n" => n, "k" => k}) do
    n = String.to_integer(n); k = String.to_integer(k)
    body = vbody(n); cs = div(n, k)
    conn = conn |> put_resp_content_type("application/octet-stream") |> send_chunked(200)
    Enum.reduce(0..(k - 1), conn, fn i, c ->
      len = if i == k - 1, do: n - i * cs, else: cs
      {:ok, c} = chunk(c, :binary.part(body, i * cs, len)); c
    end)
  end
end
EX

cat > lib/${APP}_web/live/counter_live.ex <<'EX'
defmodule DemoWeb.CounterLive do
  use DemoWeb, :live_view
  def mount(_p, _s, socket), do: {:ok, assign(socket, count: 0)}
  def handle_event("inc", _p, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}
  def render(assigns) do
    ~H"""
    <div>Count: <span id="count"><%= @count %></span></div>
    <button phx-click="inc">+</button>
    """
  end
end
EX

# wire the routes into the existing "/" scope
python3 - "lib/${APP}_web/router.ex" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
routes = '    get "/sz/:n", TynTestController, :sz\n    get "/chk/:n/:k", TynTestController, :chk\n    live "/counter", CounterLive\n'
# insert after the first `get "/", PageController, :home` line
s = re.sub(r'(get "/", PageController, :home\n)', r'\1' + routes, s, count=1)
open(p, "w").write(s)
PY

echo "=== assets.deploy + big.bin + release ==="
mix assets.deploy >/dev/null 2>&1
gen_big_bin priv/static/assets/big.bin 1500000   # 1.5 MB, exercises sendfile across many TX windows
mix release --overwrite >/dev/null 2>&1
# big.bin must survive into the release tree (Plug.Static serves non-digested files under /assets)
cp -f priv/static/assets/big.bin _build/prod/rel/${APP}/lib/${APP}-*/priv/static/assets/big.bin

echo "=== done: release at ${DEST}/_build/prod/rel/${APP} ==="
echo "next: tyn-pack it (stock deps), build-disk.sh, boot, then tests/run.sh <ip>"
