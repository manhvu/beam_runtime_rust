# Standing test infrastructure — build host, probe DB, AWS hygiene

The single home for the **out-of-band state** of the persistent test fixtures (build host, probe
Postgres, AWS role). These things live outside git, so they drift; this file is the provenance record
so a new session doesn't rediscover a change by hitting a failure. Update it whenever you change the
standing setup.

## Build host

- EC2 `ubuntu@<public-ip>` (currently `32.198.31.130`), private `172.31.5.221` (default VPC
  `172.31.0.0/16`); key `~/.ssh/april2026.pem`. Instance `i-0db3799c95adbd2b5` (`tyn-build`),
  SG `sg-01c22cbe8cb9c309d`.
- **Toolchain drift:** the *release* build uses the pinned OTP 27.3.4.2 / Elixir 1.18.3 toolchain
  (`.tool-versions`), but the host's **default** `erl`/`mix` is OTP 25 (BEAM 13.2.2.5). Consequence:
  `mix run` against a prod `_build` fails to load OTP-27-compiled beams (`{:features_not_allowed,
  [:maybe_expr]}`). Only the tyn-pack'd release (correct OTP) runs the app — so Postgrex/DB probes can
  only be exercised on a booted Tyn instance, not via `mix run` on the host.
- The kernel source at `/home/ubuntu/kernel` is **hand-synced, not a git clone** (`git archive HEAD src
  | ssh … tar -x` is how it's refreshed). `deploy-ami.sh` builds from it.

## Standing probe Postgres (on the build host, `172.31.5.221:5432`)

- Database `tyndb`, user `tyn`. Postgres 16, `password_encryption = scram-sha-256`, `ssl = on`
  (self-signed cert — `sslmode=require` gives real TLSv1.3; plaintext also accepted).
- **`pg_hba.conf` is the load-bearing detail** — two rules with very different behaviour:
  - `host all all 172.31.0.0/16 trust` → **VPC connections need no password** (why plaintext `[[42]]`
    and passwordless `psql host=172.31.5.221` "just work").
  - `host all all 127.0.0.1/32 scram-sha-256` → **loopback needs SCRAM** (the *meaningful* TLS path:
    a sidecar connecting to `127.0.0.1:5432` must do real TLS + SCRAM).
- ⚠️ **`tyn`'s password was changed to `tynpass123`** (2026-08, for the TLS-to-DB pgbouncer SCRAM proof;
  `docs/CAPABILITY_MAP.md` Path B). The original SCRAM hash is **unrecoverable**, so this can't be
  reverted — but the `172.31.0.0/16 trust` path ignores the password, so existing passwordless probes
  are unaffected. If a probe needs SCRAM (loopback / a proxy), the password is `tynpass123`.
- A `pgbouncer` (`/etc/pgbouncer/pgbouncer.ini`, runs as the `postgres` user, logfile `/tmp`) is
  installed for the sidecar proof; left stopped. `stunnel4` is also installed (`/etc/stunnel/
  pg-sidecar.conf`) — **do not use it for Postgres** (SCRAM passthrough breaks; see DEPLOY.md).

## AWS hygiene — the build-host role can't clean up after itself (fix the class once)

Role `tyn-build-role` (attached to `i-0db3799c95adbd2b5`) can **create** but not **remove** several
resource types, so benign leftovers accumulate every probe session. This is now a **pattern, not a
one-off** — worth one IAM policy addition rather than re-flagging each session.

**Missing permissions (add to the role):**
- `ec2:RevokeSecurityGroupIngress` — the role can `Authorize` but not `Revoke`, so opened SG rules
  can't be closed.
- AMI-sharing / cleanup perms (the earlier `ModifyImageAttribute`/share-block asymmetry).

**Current benign leftovers to sweep** (all in-VPC-only or cost-free; nothing listening):
- SG `sg-01c22cbe8cb9c309d`: ingress `tcp/9100` (dist spike) and `tcp/6432` (TLS sidecar), both from
  `172.31.0.0/16`.
- (Historically) the dist security group + rules noted in `[[project_layer4_capmap]]`.

Grant the two permissions above, then a single `revoke-security-group-ingress` pass clears the SG
rules. Until then, these are documented-and-benign, not lost.

## Related infra-hygiene items

Same family, tracked elsewhere: the pinned `.tool-versions` (toolchain drift, above), the gitignored
build config, and the `docs/BUILDING_ERTS.md` base-image build path.
