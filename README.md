# AWS EC2 Cloudflare DDNS + Flux bootstrap

This repository contains a non-interactive EC2 User Data Bash script for Ubuntu
22.04/24.04 and Debian 12.

It reads the EC2 public IPv4 (IMDSv2 first), then creates or updates only the
exact A record configured as `DOMAIN`. It uses a Cloudflare API Token, forces
`proxied=false`, retries temporary network failures, then runs the Flux
installer and applies TCP tuning. The installation order is DNS → Flux → TCP →
periodic DDNS timer.

It also applies persistent TCP tuning: BBR congestion control, FQ
queue discipline, 16 MiB receive/send buffer ceilings, TCP buffer autotuning,
MTU probing, TCP Fast Open, disabled slow start after idle, and the requested
connection/backlog limits. The settings are saved in
`/etc/sysctl.d/99-ec2-bbr-tuning.conf`.

After the first successful run, it installs a systemd timer. The timer checks
the EC2 public IPv4 about 30 seconds after boot and then every minute. It only
writes Cloudflare DNS when the A record needs a change and never re-runs the
Flux installer during periodic checks.

`--enable-periodic-only` is intentionally for an existing instance that only
needs its DDNS timer configured or reconfigured. It skips Flux installation and
TCP tuning. For a new EC2 instance, omit that option and provide both
`--flux-address` and `--flux-secret`.

## Security

This repository intentionally contains **no credentials**. Keep all of these
values private:

- `CF_API_TOKEN`
- `CF_ZONE_ID`
- `FLUX_ADDRESS`
- `FLUX_SECRET`

Before using the script, edit the configuration block at its top. Do not commit
the populated version back to this repository.

## Use as EC2 User Data

Either paste the complete script directly into EC2 User Data after configuring
it, or download the public template and inject configuration through a private
deployment process. For a safe read-only validation first, set `DRY_RUN=true`.

For the latter method, use `outputs/ec2-one-click-bootstrap.sh`: configure its
private values locally, then paste the entire file into EC2 User Data. It
downloads the public template and passes those values only to the local process.

Logs are written to `/var/log/cloudflare-ddns.log` and also appear in cloud-init
output.

## Script

[`outputs/cloudflare-ddns-and-flux-user-data.sh`](outputs/cloudflare-ddns-and-flux-user-data.sh)
