---
name: tailscale-derp-bootstrap
description: Deploy, verify, or troubleshoot the Drswith/tailscale-derp-bootstrap project on a public IPv4 VPS using native systemd or Docker Compose. Use for this repository's DERP installer, tailnet enrollment, IP certificates, upgrades, and real client relay checks.
---

# Tailscale DERP Bootstrap

Use the current repository checkout as the source of truth. The project is at https://github.com/Drswith/tailscale-derp-bootstrap. When this skill was installed with skills.sh, its directory may be outside the checkout; locate the checkout from the user's task before reading or running project files. Do not assume a version or script path based solely on this skill.

## Route the task

1. Read `README.md` and the relevant `docs/deployment/bare-metal.md` or `docs/deployment/docker.md` in the checkout. For upgrades and incidents, also read `docs/operations.md`; for support claims, read `docs/verification.md` and the current `lib/platform.sh`.
2. Choose one mode. Native uses `install.sh` and a host `config.env`; Docker uses `docker/deploy.sh` and `docker/config.env`. Keep their ports and state separate. Check `versions.lock` and the matching example config before supplying commands.
3. Confirm the target has a fixed public IPv4, supported system/architecture, systemd, enough disk, and planned ingress for DERP TCP 52625 and STUN UDP 3478 by default while retaining SSH. Public TCP 80 is still required for the current Let's Encrypt IP certificate's HTTP-01 issuance and renewal; changing the DERP port does not replace it. DERP does not use TCP 80, 443 or 8080 by default. The scripts do not change cloud security groups, host firewall or tailnet policy.
4. Copy the matching example config, edit only with trusted operator data, and keep it out of Git. Config files are shell-sourced. Never put Auth keys or OAuth secrets in config values, command arguments, Git, or logs. For headless enrollment use the script's `0600` credential file and a suitable non-ephemeral identity; for OAuth, configure the dedicated tag and `TS_ADVERTISE_TAGS`. The current four-host record reports an unresolved ordinary Auth key rejection, while tagged OAuth enrollment worked.
5. Run the mode's `preflight`, then `install`, then `check` and `derpmap`. Interactive Docker login needs `docker/deploy.sh logs` and device authorization before `check`. On minimal hosts, `install` can add base packages that `preflight` needs.
6. Merge only the printed DERP region into the existing policy. Preserve official regions, grants/ACL, SSH and tags. Validate from another network that the public TLS certificate has the IP SAN, then check effective DERP map, STUN and an actual relay path between authenticated tailnet clients. Distinguish a direct path, a debug command's random key, and a real relayed client.

## Diagnose without guessing

- On download failure, inspect direct and proxy paths separately for the affected client (Tailscale package source, Docker Hub, Go download/modules, PyPI or ACME). Check current proxy port and hosts; use `NO_PROXY` for internal/LAN addresses. A Go mirror is acceptable only with `GOSUMDB` still enabled and the official Go archive SHA-256 from `versions.lock` still enforced.
- `install.sh check` and `docker/deploy.sh check` verify local state; they do not prove cloud ingress, tailnet policy delivery or actual relay. GitHub Actions verify amd64 package/build compatibility, not a live DERP deployment.
- Before reporting success, state separately which layers were observed: package/build, host service, ACME/IP SAN and served TLS, external TCP/UDP, effective policy, authenticated relay, reboot/renewal. Cite the current evidence; do not inherit a historical VPS result for a reinstalled host.

For repository changes, follow the checkout's `AGENTS.md` and run `bash tests/local.sh`. For a live deployment, follow the current deployment guide for the chosen mode and use the user's supplied host and credentials only within the authorized task.
