# Building ERTS + the VFS

Tyn embeds a statically-linked, musl-libc, BeamAsm-JIT `beam.smp` and a cpio archive of `.beam`
files. Both are committed (`src/beam.smp.elf`, `src/otp-rootfs.cpio`) so the kernel builds out of
the box; this is how to rebuild them.

---

## 1. Reproducible build (recommended): `beam-build/`

The emulator is built reproducibly in Docker/Alpine — musl-native, so Alpine's `g++` builds the
C++17 BeamAsm JIT against musl with no cross-toolchain. Every input is pinned in
`beam-build/Dockerfile` (Alpine 3.19 → GCC 13.2 / musl 1.2.4, OTP 27.3.4.2).

```bash
./beam-build/build-beam.sh                       # -> beam-build/beam.smp (stripped)
./beam-build/build-beam.sh --nif-modules tyn_nif # optional: statically link a NIF
```

Key properties of this build (see the Dockerfile comments for the full rationale):

- **Unmodified OTP 27 source.** No spin-count patches, no monotonic-time patches — Tyn calibrates
  the TSC and runs `ERTS_CHECK_MONOTONIC_TIME` at defaults (see `docs/FUTEX_HISTORY.md` H13). The
  only non-default `configure` flags are `--enable-jit`, `--without-ssl`, and `--without-*` for
  apps Tyn never ships.
- **Fully static musl (`-static`), BeamAsm JIT enabled**, no OpenSSL (Tyn's `:crypto` is a
  from-scratch Rust NIF — see below).
- **GCC major version is pinned deliberately.** GCC 14 measurably worsened the cold-boot
  futex-stall reliability under stress; the scheduler's timing is codegen-sensitive.
- `make emulator` may return nonzero because the `erlexec`/`epmd` helpers don't link under
  `-static` — that's expected; Tyn loads `beam.smp` directly and gets `erl_child_setup` from the
  cpio. The build fails hard only if `beam.smp` itself is missing.

Statically linking a NIF (e.g. Tyn's `:crypto`) uses `--enable-static-nifs`; the archive is named
after the module (`tyn_nif.a` → `tyn_nif_nif_init`) so `load_nif` finds it. See the Dockerfile.

---

## 2. Manual cross-compile (reference)

Equivalent by hand on an x86_64 Linux host with `musl-gcc`:

```bash
git clone --branch OTP-27.3.4.2 https://github.com/erlang/otp.git otp27 && cd otp27
./configure --enable-jit --without-ssl --without-wx --without-observer \
  --without-debugger --without-et --without-megaco --without-odbc --without-jinterface \
  CC=musl-gcc CFLAGS="-O2 -static" LDFLAGS=-static
make -j$(nproc) emulator
strip bin/x86_64-pc-linux-musl/beam.smp -o ../src/beam.smp.elf   # ~10 MB static ELF
```

---

## 3. Package the VFS (base OTP cpio)

The base image ships OTP `kernel`/`stdlib` (and optionally Elixir) `.beam` files. Application
images are built on top with `tyn-pack` (see `docs/DEPLOY.md` §3) — this is only the base.

```bash
mkdir -p staging/otp/bin && cp otp27/bin/start.boot staging/otp/bin/
# versioned ebin paths for the boot script...
for d in otp27/lib/kernel-*/ebin otp27/lib/stdlib-*/ebin; do
  v=$(basename $(dirname $d)); mkdir -p staging/otp/lib/$v/ebin
  cp $d/*.beam staging/otp/lib/$v/ebin/
done
# ...plus a flat copy at the root for code_server fallback loading
cp otp27/lib/kernel-*/ebin/*.beam otp27/lib/stdlib-*/ebin/*.beam staging/
cd staging && find . -type f | sed 's|^\./||' | cpio -o -H newc > ../src/otp-rootfs.cpio
```

### Elixir (optional)

```bash
curl -L -o elixir.zip \
  https://github.com/elixir-lang/elixir/releases/download/v1.18.3/elixir-otp-27.zip
unzip elixir.zip -d elixir
# The .beam files — AND the OTP-app .app resource files. The .app files are not
# optional cosmetics: without elixir.app the application controller can't resolve
# `elixir` as a started app, and any dep that inspects it at init (Ecto's Repo
# calls Code.ensure_loaded?/1) fails with "module Code is not available". Ship
# elixir/logger/eex/iex/mix .app alongside the beams.
for a in elixir logger eex iex mix; do
  cp elixir/lib/$a/ebin/*.beam staging/ 2>/dev/null || true
  cp elixir/lib/$a/ebin/$a.app  staging/
done
cd staging && find . -type f | sed 's|^\./||' | cpio -o -H newc > ../src/otp-rootfs.cpio
```

### `tyn_boot.beam` — always compile from source

The base cpio also carries `tyn_boot.beam` (the app-agnostic boot entry the kernel `-eval`s).
It is compiled from [`src/erl/tyn_boot.erl`](../src/erl/tyn_boot.erl) and **must be rebuilt whenever
that source changes** — a stale beam once silently disabled `runtime.exs` evaluation and the
boot-time resolver config, which broke the standard eager-Ecto path in a way no error message named:

```bash
erlc -o staging src/erl/tyn_boot.erl   # overwrites the flat-root tyn_boot.beam
```

### The committed, reproducible path: `build-rootfs.sh`

Rather than run the two source-derived steps above by hand (which is how they went stale),
[`build-rootfs.sh`](../build-rootfs.sh) does them reproducibly: it seeds from the current
`src/otp-rootfs.cpio`, **always recompiles `tyn_boot.beam`** from source (`erlc +deterministic`),
**adds the Elixir `.app` files** from the pinned toolchain (see [`.tool-versions`](../.tool-versions)),
repacks, and byte-checks that all of them are present in the *output*. The repack is
**byte-reproducible** — zeroed mtimes + sorted member order — so the output `md5` is a stable
fingerprint (rebuilding from the committed cpio is a fixpoint: same bytes out). Requires
`erlc`/`elixir` on `PATH`.

```bash
./build-rootfs.sh                          # rewrite src/otp-rootfs.cpio in place, print md5
OUT=/tmp/new.cpio ./build-rootfs.sh        # write elsewhere (validate before committing)
```

Fully regenerating the accreted dependency beams (Phoenix/Bandit/telemetry/…) from a mix build is
a separate, larger task; `build-rootfs.sh` refreshes only the two components that must derive from
source, and preserves the rest of the proven base.

---

## Version policy

Compiling with an **older** OTP than the runtime is safe (old `.beam` loads on new ERTS);
`tyn-pack` **rejects** a release whose OTP/ERTS or Elixir exceeds Tyn's base — rebuild the release
with OTP ≤ 27. The base ERTS version is the one inside `beam.smp` (OTP 27.3.4.2 / ERTS 15.2.7.1).
