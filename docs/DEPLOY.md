# Deploying Tyn

Three paths, shortest first: run the public demo on AWS, run locally under QEMU/KVM, or
package and deploy **your own** Phoenix/Elixir app.

---

## 1. Try the public demo on AWS (no build)

The public AMI carries a stock `mix phx.new` app — landing page, a **LiveView counter**, and
static assets served through the kernel's `sendfile(2)` — so it demonstrates the capability
claims directly.

**AMI:** `ami-09619e2d139f2a57d` (us-east-1)

```bash
# One-time: a security group with port 8080 open
SG_ID=$(aws ec2 create-security-group --group-name tyn-demo \
    --description "Tyn demo - HTTP on 8080" --region us-east-1 \
    --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
    --protocol tcp --port 8080 --cidr 0.0.0.0/0 --region us-east-1

# Launch
INSTANCE_ID=$(aws ec2 run-instances --image-id ami-09619e2d139f2a57d \
    --instance-type c5.large --security-group-ids $SG_ID --region us-east-1 \
    --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --region us-east-1 --instance-ids $INSTANCE_ID
IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region us-east-1 \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "Tyn is at http://$IP:8080"
```

Wait ~10 s for boot, then:

```bash
curl http://$IP:8080/                         # Phoenix landing page (HTML)
curl -s http://$IP:8080/assets/big.bin | wc -c  # 1500000 — a static asset via kernel sendfile(2)
# then open http://$IP:8080/counter in a browser: the LiveView counter increments live
```

**Terminate when done** (instances accrue hourly charges):

```bash
aws ec2 terminate-instances --region us-east-1 --instance-ids $INSTANCE_ID
```

The security group persists for future launches (no recurring cost). Any Nitro instance type
works (c5, m5, t3, r5, …) — the ENA driver auto-detects the NIC.

### Serial console (interactive BEAM shell, no open port)

A live Erlang/Elixir eval shell over the EC2 Serial Console — IAM-authenticated:

```bash
aws ec2 modify-serial-console-access --serial-console-access-enabled --region us-east-1
SSH_KEY=~/.ssh/id_ed25519   # adjust to your key
aws ec2-instance-connect send-serial-console-ssh-public-key \
    --instance-id $INSTANCE_ID --serial-port 0 \
    --ssh-public-key file://${SSH_KEY}.pub --region us-east-1 && \
ssh -i $SSH_KEY -o StrictHostKeyChecking=no \
    $INSTANCE_ID.port0@serial-console.ec2-instance-connect.us-east-1.aws
```

```
>> erlang:system_info(emu_flavor).
jit
>> erlang:memory().
[{total,18124768}, ...]
```

`Enter` then `~.` to disconnect.

---

## 2. Run locally under QEMU/KVM

**Prerequisites:** Rust nightly with `rust-src`, and QEMU with KVM. A prebuilt `beam.smp` +
OTP/Elixir rootfs are committed, so the kernel builds out of the box (to rebuild them, see
[`BUILDING_ERTS.md`](BUILDING_ERTS.md)).

```bash
cargo build --release --target x86_64-tyn.json \
  -Zbuild-std=core,alloc,compiler_builtins -Zbuild-std-features=compiler-builtins-mem

qemu-system-x86_64 -kernel target/x86_64-tyn/release/tyn-kernel \
  -m 2560M -machine q35 -cpu host -enable-kvm -smp 8 \
  -nographic -no-reboot -serial mon:stdio \
  -device virtio-net-pci,netdev=net0,disable-legacy=on,disable-modern=off \
  -netdev user,id=net0,hostfwd=tcp::5555-:8080,hostfwd=tcp::5567-:9090
```

> **Use KVM (`-enable-kvm`), not TCG.** Software emulation (`-accel tcg`) deterministically
> `#PF`s at boot on some images; real hardware / KVM is unaffected. See the README Limitations.

Once it prints `phoenix_listening`, from another terminal: `curl http://localhost:5555/`, and
`nc localhost 5567` for the eval shell.

---

## 3. Deploy your own Phoenix/Elixir app

Tyn packages a standard **Mix release** into a bootable image with `tyn-pack` → `build-disk.sh`
→ (for AWS) `deploy-ami.sh`. No kernel rebuild.

### Prerequisites (verified on a clean Ubuntu 24.04 box)

- **Elixir 1.15–1.18 on OTP ≤ 27.** The distro packages are too old (Ubuntu 24.04 ships Elixir
  1.14 / OTP 25, which can't compile a modern Phoenix app — `hpax` needs Elixir ≥ 1.15). Install a
  pinned toolchain, e.g. with [asdf](https://asdf-vm.com):

  ```bash
  sudo apt-get install -y build-essential autoconf m4 libncurses-dev libssl-dev unzip
  git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.1
  . ~/.asdf/asdf.sh
  asdf plugin add erlang && asdf plugin add elixir
  asdf install erlang 27.3.4.2 && asdf global erlang 27.3.4.2      # matches Tyn's base OTP
  asdf install elixir 1.18.3-otp-27 && asdf global elixir 1.18.3-otp-27
  ```

  These exact versions are pinned in the repo's committed [`.tool-versions`](../.tool-versions), so
  from the repo root a bare `asdf install` (after the two `apt`/`asdf plugin add` steps above)
  installs the right toolchain with no version arguments — the machine-readable complement to this
  prose. (The versions must not exceed Tyn's base OTP 27.3.4.2 / ERTS 15.2.7.1; `tyn-pack` rejects a
  release that does.)

- **AWS CLI v2** (for `deploy-ami.sh`) + credentials (`aws configure`, or an instance role):

  ```bash
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
  unzip awscliv2.zip && sudo ./aws/install
  ```

- **Disk-image tools** (`build-disk.sh`): `parted grub-pc-bin e2fsprogs` (present on stock Ubuntu
  server). `build-disk.sh` uses `sudo` internally — run it as your normal user, **not** under `sudo`.

### Build a release (starting from scratch)

```bash
mix archive.install hex phx_new 1.7.14 --force
mix phx.new my_app --no-ecto        # or your existing app
cd my_app && mix deps.get
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release            # OTP <= 27; older is fine, newer is rejected
```

### Pack it into a Tyn cpio

```bash
./tyn-pack _build/prod/rel/my_app -o my_app.cpio --app my_app --port 8080 \
    --env SECRET_KEY_BASE=$(openssl rand -hex 40) \
    --env PHX_SERVER=true --env PORT=8080
```

`tyn-pack` emits the release layout, records code paths, ships `runtime.exs`, and sets boot-time
env vars. Core OTP/Elixir apps come from Tyn's base image; everything else (Phoenix, Bandit,
your app, its deps) comes from your release — **unmodified**. `tyn_boot` evaluates `runtime.exs`
at boot and deep-merges it, so a stock app's config Just Works.

### Boot it (local) or deploy it (AWS)

```bash
CPIO=my_app.cpio ./build-disk.sh          # -> a bootable raw disk image
# local: qemu ... -drive file=<image>,format=raw,if=virtio ...
# AWS:   CPIO=my_app.cpio ./deploy-ami.sh  # S3 -> import-snapshot -> register AMI -> launch
```

### Two things every real deployment needs

- **Terminate TLS at the load balancer.** Tyn has no in-guest TLS (`ssl`/`public_key`/`asn1`
  are stubs). Put an ALB/NLB in front, terminate HTTPS there, and serve plain HTTP in-guest
  (`scheme: "http"`). An `https:` listener starts then `:undef`s at request time.
- **Set `check_origin` for LiveView.** On a bare IP or any host that doesn't match the endpoint's
  configured URL host, Phoenix returns `403` on the LiveView WebSocket. In `runtime.exs`:

  ```elixir
  config :my_app, MyAppWeb.Endpoint,
    check_origin: ["//myapp.example.com"]   # your real host(s)
    # check_origin: false   # ONLY for a throwaway IP demo — it disables CSWSH protection
  ```

See the README **Limitations** for the full list (epoch wall clock, no writable FS, no
distributed Erlang, ~3% cold-boot stall → retry at the orchestration layer).
