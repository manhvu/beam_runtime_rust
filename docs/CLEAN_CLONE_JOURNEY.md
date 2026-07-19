# Clean-clone user journey (PRE_ANNOUNCE Part 3) — findings log

The real test: a **fresh box**, following **only the README + docs/DEPLOY.md**, no build-host
leakage (no scp, no reused toolchain/artifacts). Every gap that needed knowledge not in the docs
is a **README bug** — logged here whether or not it was fixed, because the list is the evidence of
how much "it works" lived in one head.

**Every result names the artifact it ran against (box / AMI / instance ID).**

## Environment
- Fresh box: a stock **c5.4xlarge, Ubuntu 24.04** instance, launched clean for this run (and
  terminated afterward — a warm box is how build-host state creeps back into "verified" claims).
- Deploy target: AWS Nitro (us-east-1)

## Findings
_(numbered as discovered; F1, F2, …)_

- **F1 — README build command fails on current nightly.** `rust-toolchain.toml` pins the
  *floating* `channel = "nightly"` (no date), so a newcomer gets the newest nightly, which now
  requires `-Zjson-target-spec` for `.json` target files — a flag the README's `cargo build`
  command omits. Fails immediately: `error: .json target specs require -Zjson-target-spec`. The
  build host only works because its cached nightly is older. **Fix:** pin a dated nightly in
  `rust-toolchain.toml` AND add `-Zjson-target-spec` to the documented build command.
  (nightly 2026-07-18.)
- **F2 — missing prerequisite: a C compiler.** The README prereqs list Rust + QEMU but not
  `build-essential`/`gcc`. rustc needs `cc` to link build scripts and proc-macros; without it the
  build dies with the cryptic `could not compile <crate> (build script) ... No such file or
  directory (os error 2)`. **Fix:** add `build-essential` to the README prerequisites.
  (Confirmed: `which cc` empty on a stock Ubuntu 24.04 box.)
- **F3 (tentative) — default build parallelism can OOM.** dmesg showed OOM events during the
  unbounded (`-j16`) build-std build on a 32 GB c5.4xlarge; bounding to `-j6` avoids it. To
  confirm vs incidental. **Possible fix:** note memory/`-j` guidance, or a `.cargo/config` jobs cap.
- **F4 — THE SHOWSTOPPER: the build config is gitignored, so a clean clone cannot build at all.**
  The build host's `kernel/.cargo/config.toml` sets `json-target-spec = true`, `build-std`, and
  `[build] target = "x86_64-tyn.json"` — but `.gitignore` line 4 is `.cargo/`, so it's never
  committed. A fresh clone has none of it; the README's `cargo build` then fails on the current
  nightly (no `json-target-spec`). This is the essential build config living only on one box.
  **Fix:** commit `.cargo/config.toml` (un-ignore it). With it + the F1 pin, a clean clone builds
  (verified: `BUILD_EXIT=0`, 52 MB kernel on the fresh box with nightly-2026-06-01). The
  config also makes the build command just `cargo build --release` (target + build-std come from
  the config), so the README's long `-Zbuild-std=...` invocation is redundant once it's committed.
- **F6 — deploy path: no Elixir/OTP install guidance, and the distro version can't build a Phoenix
  app.** `docs/DEPLOY.md` §3 opens at `mix release` (a newcomer has no app *and* no Elixir). Naive
  `apt install elixir` on Ubuntu 24.04 gives **Elixir 1.14.0 / OTP 25**, which fails to compile a
  stock `phx.new` app — the `hpax` dep uses `^prefix` syntax needing **Elixir ≥ 1.15**
  (`CompileError ... cannot use ^prefix outside of match clauses`). So the real constraint is
  **Elixir 1.15–1.18 AND OTP ≤ 27**, installed via asdf/kerl/ESL, plus Erlang build deps
  (`autoconf m4 libncurses-dev libssl-dev`) — none of which DEPLOY.md states. **Fix:** DEPLOY.md
  must add `mix phx.new` as the starting step and a concrete Elixir/OTP install (recommend asdf with
  pinned `erlang 27.3.4.2` + `elixir 1.18.3-otp-27`, and the build deps). (the fresh box.)
- **F7 — AWS CLI not installed / not documented.** `docs/DEPLOY.md` §3 runs `deploy-ami.sh` (which
  needs `aws`) but never says to install the AWS CLI or configure credentials. (Other deploy tools —
  `parted`, `grub-install`, `mkfs.ext2`, `losetup`, grub `i386-pc` modules — were present on stock
  Ubuntu 24.04, so those are fine.) **Fix:** DEPLOY.md must list the AWS CLI + credential setup.
- **F8 — tyn-pack silently fails when Erlang isn't at `/usr/lib/erlang` (i.e. the asdf install F6
  requires).** tyn-pack globs `/usr/lib/erlang/lib/compiler-*/...` for core OTP apps not in the
  release; with asdf Erlang (`~/.asdf/installs/erlang/.../lib`) the glob is empty and tyn-pack
  **cleans up and exits 0 with no cpio** — no error. It has an `OTP_LIB` env override, undocumented.
  Setting `OTP_LIB=$(erl -noshell -eval 'io:format("~s/lib",[code:root_dir()]),halt().')` fixed it
  (35 MiB cpio). **Fix:** tyn-pack should auto-detect the OTP lib via `code:root_dir()` and **die
  loudly** if core apps aren't found; DEPLOY.md should mention `OTP_LIB` for non-system Erlang.
  This directly compounds F6 — the install method the docs force (asdf) breaks the next tool.
- **F5 — gitignore audit (prompted by F4): no OTHER hidden-essential files.** Checked everything
  the build embeds (`include_bytes!`/`include_str!` → `src/{multiboot.S,trampoline.bin,
  beam.smp.elf,otp-rootfs.cpio}`, all tracked) and everything the deploy path references
  (`build-disk.sh`, `deploy-ami.sh`, `tyn-pack`, all `src/erl/*.beam`, `Cargo.toml`, `Cargo.lock`,
  `x86_64-tyn.json`, `rust-toolchain.toml`). All tracked; no `*.beam/*.bin/*.elf/*.cpio/*.app`
  ignored anywhere. The remaining ignored entries (limine/iso artifacts — an abandoned boot path;
  `CONTEXT.md`/`REVIEW.md` notes; `/run.sh` scratch; the old `tests/*.rs` no_std kernel tests) are
  genuinely non-essential. **`.cargo/config.toml` was the only one.** (F4/F1/F2 fixed + pushed in
  0e961a1.)

- **F9 — beam-build needs Docker, undocumented.** `docs/BUILDING_ERTS.md` runs `beam-build/
  build-beam.sh` (which uses Docker) but doesn't list Docker as a prerequisite. Minor. **Fix:** note
  `docker.io` (and that build-beam.sh needs `sudo docker` unless the user is in the docker group).

## Result summary (all steps run on the fresh box, from README + docs/DEPLOY.md only)
- **Steps 1–3 (clone, prereqs, build): PASS after F1/F2/F4 fixes.** git clone (public, F0 clean),
  rustup + build-essential, `cargo build --release` → 52 MB kernel.
- **`beam-build/` reproducibility (gap #3): PASS.** Clean Docker build (Docker installed per F9)
  produced a working static-musl beam.smp, 10,577,640 B vs committed 10,577,704 B — 64-byte
  BuildID/metadata diff, functionally identical. The committed recipe reproduces on a stateless box.
- **Steps 4–6 (Elixir/OTP, phx.new, tyn-pack, build-disk, deploy-ami, curl+session): PASS after
  F6/F7/F8 fixes.** Deployed a stock phx.new app to Nitro (the deployed Nitro instance): `/` 200, app.js
  125737 B byte-exact via kernel sendfile, signed session-cookie round-trip verified (crypto).
  Validation deploy torn down.
- **Step 7 (serial console): mechanism-validated** (the serial eval shell was proven earlier this
  session, commit 0280a48); the one-shot scripted test over interactive serial-over-SSH didn't
  cleanly capture output — a harness limitation, not a deploy defect. Interactive/human check.

**Fixes committed + pushed: 0e961a1 (F1/F2/F4 build) and 426b2c0 (F6/F7/F8 deploy).** The repo now
builds AND deploys from a clean clone; before this run it did neither for anyone but the build host.

## Journey steps (from README + docs/DEPLOY.md)
1. git clone
2. install prerequisites
3. build the kernel; attempt `beam-build/` reproducibility
4. `mix phx.new` a fresh app
5. `tyn-pack` → `build-disk.sh` → `deploy-ami.sh`
6. curl + session-cookie round-trip
7. serial console

## Gap #4 (committed cpio vs AMI demo) — resolved via option B
Rather than commit a Phoenix demo cpio (which bakes a SECRET_KEY_BASE — a committed secret in a
public repo) + re-align the AMI, the README Run section now **states the split explicitly**: the
committed image boots a minimal bench app (boot/serve/BEAM check), while the full Phoenix demo
(assets + LiveView) is the public AMI + the "deploy your own app" path. One less secret, honest.

## Standing note — do not treat this as permanently settled

The repo is only **known-buildable and known-deployable as of the last time someone ran this from a
genuinely clean box.** Toolchains move (the floating-nightly breakage in F1 is the proof), and it is
easy to reintroduce a build-host dependency without noticing. **Re-run this journey from a fresh box
before any future release** — do not assume it still holds.

This document is also the *reason* several things in the repo look the way they do: the dated
`nightly-2026-06-01` pin (F1), the committed `.cargo/config.toml` (F4), `build-essential` in the
prerequisites (F2). They are not clutter to tidy up — they are what makes the repo build for anyone
but the original author. If you're tempted to "clean one up," read the matching finding first.
