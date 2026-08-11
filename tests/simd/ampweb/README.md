# ampweb — HTTP md5-preemption amplifier (Nitro-observable)

The serial `ampapp` amplifier (sibling dir) proves BUG-1 on TCG by printing
`AMP_TOTAL` to the serial console. On Nitro that console **does not reach**
`get-console-output`, so the only observability is HTTP. `ampweb` runs the *same*
measured md5 workload but reports over a raw-`gen_tcp` endpoint, so BUG-1's fix can
be validated under real-hardware timing — and it is the seed of the Phase-2 suite's
Nitro HTTP reporting path.

## Workload

16 workers (`TYN_AMP_WORKERS`) each hold a reference md5 of a known 32 B and 64 KiB
binary and recompute them in a tight loop under binary-allocator churn
(`TYN_AMP_CHURN_KB`, `TYN_CHURN_TYPE`), with the exact input/reference/recompute
disambiguation of `ampapp` so only a **genuine transient** (input intact, reference
still valid, digest momentarily wrong = BUG-1's red-zone clobber) is counted. Totals
accumulate in an ETS table; `Ampweb.Http` serves them.

## Endpoints

- `GET /health` → `ok`. Liveness — and therefore the **crash detector** on Nitro: a
  node-level crash (BUG-1's `size_object: bad tag`) takes the VM down and `/health`
  goes dark.
- `GET /chk` → `iters small_md5 large_md5 input_corrupt ref_bad worker_exits workers`.

## Gates (real-hardware validation of BUG-1 / Path A)

**`large_md5 == 0` AND the node stays alive** (`/health` keeps answering) under
sustained load. `small_md5` is the no-trap anchor (must be 0). `worker_exits` counts
Elixir-level worker crashes (respawned); a node crash shows as `/health` dark.

## Teeth-tested (the instrument detects both failure modes)

Controlled A/B, same production beam `a9048ee0`, same image, same ~110 s TCG window,
only the kernel trampoline differing:

| kernel | `large_md5` | `/health` |
| --- | --- | --- |
| unfixed (`0b258c3`, red-zone `ret`) | **5** (corruption) | **200 → dead** (crash) |
| Path A (`iretq`) | **0** | **200** throughout (iters→14235) |

So a clean Nitro reading is a real pass, not a measurement that could not fail.

## Build & run

```
# OTP 27 toolchain (pinned in .tool-versions)
cd tests/simd/ampweb && MIX_ENV=prod mix release --overwrite
# pack onto the base OTP cpio, boot, curl :8080/chk — see tests/simd/mkdisk.sh
../../../tyn-pack _build/prod/rel/ampweb --base ../../../src/otp-rootfs.cpio -o ampweb.cpio
```

Zero-dependency (only `:erlang.md5`, `:binary.copy`, `:gen_tcp`) — no
`:crypto`/`:ssl`/Plug/Bandit, so the image is minimal and the measurement isolates
the kernel behaviour under test from application dependencies.
