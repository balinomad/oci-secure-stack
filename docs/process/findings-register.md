---
name: "Findings Register"
description: |
  Stable register of findings with severity, evidence, confidence, and status, plus runtime questions that require deployment tests.
status: active
version: 1.0
updated: 2026-11-12
---

# Findings Register

Stable IDs. Do not renumber. Status changes require evidence.

Legend: Open, Needs verification, Deferred, Fixed.

## P0: deployment blockers and correctness

| ID  | Severity | Finding                                                                                                                                                                     | Evidence                                                                                                        | Confidence | Status             |
| --- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ---------- | ------------------ |
| F1  | P0       | Authelia likely cannot read its config or write its database. Files are root-owned `0600`, `/data/authelia` is `root:root`, and the official image runs as a non-root user. | `cloud-config:620-645`, unit at `419-441`                                                                       | 70%        | Needs verification |
| F2  | P0       | `/data` mount failure is non-fatal. `mount /data \|\| true` lets services write state to the ephemeral root disk.                                                           | `cloud-config:505-518`                                                                                          | 100% code  | Open               |
| F3  | P0       | Any existing filesystem is mounted as XFS. The script checks for a filesystem, not for `TYPE=xfs`.                                                                          | `cloud-config:506-514`                                                                                          | 95%        | Open               |
| F4  | P0       | No fail-fast on Vault fetch. A failed `oci secrets` call leaves empty credentials and boot continues.                                                                       | `cloud-config:575-602`                                                                                          | 90%        | Open               |
| F5  | P0       | `verify-stack.sh` runs `wg show wg0` on the host. wg-easy uses a bridge network, so the interface is in the container namespace. The check fails even when the VPN works.   | `verify-stack.sh:189`, `cloud-config:459-469`                                                                   | 85%        | Needs verification |
| F6  | P0       | Dashboard and metrics are still routed publicly as `traefik.` and `metrics.` hostnames, contradicting the localhost-only decisions.                                         | `cloud-config:159-178`, `docs/process/component-research.md:79-80`, `docs/process/archive/work-plan.md` Phase 1 | 100%       | Open               |
| F7  | P0       | `global-security-headers` is defined but never attached to a router. HSTS and related headers are inactive.                                                                 | `cloud-config:234-243`                                                                                          | 100%       | Open               |
| F8  | P0       | The metrics route points at Traefik's own metrics entrypoint, not PCP. Host metrics are not exported at all.                                                                | `cloud-config:197-200`                                                                                          | 100%       | Open               |
| F9  | P0       | Cockpit is directly reachable on port 9090 from the VPN through a firewalld rich rule. It bypasses Traefik and Authelia, and there is no localhost bind override.           | `cloud-config:741`                                                                                              | 90%        | Open               |
| F10 | P0       | Authelia runs rootful, while the decision record prefers rootless. Infrastructure containers also use plain `podman run`, not Quadlet.                                      | `cloud-config:419-441`, `docs/process/component-research.md:63-66`                                              | 100%       | Open               |

## P1: security and reliability

| ID  | Severity | Finding                                                                                                                   | Evidence                                                                                                                                   | Confidence | Status             |
| --- | -------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ---------- | ------------------ |
| F11 | P1       | `deploy-service.sh` writes `--env` values, potentially secrets, into a world-readable `0755` manifest under `/data/apps`. | `deploy-service.sh:220-239`                                                                                                                | 100%       | Open               |
| F12 | P1       | wg-easy receives `--cap-add SYS_MODULE`, which is unnecessary and broad.                                                  | `cloud-config:462`                                                                                                                         | 80%        | Open               |
| F13 | P1       | The script claims to restrict volume sources to `/data/containers` but performs no validation.                            | `deploy-service.sh:19-20` versus `125-130`                                                                                                 | 100%       | Open               |
| F14 | P1       | Manifest replay uses `realpath "$0"`, so it breaks if the script is not at the same path after VM replacement.            | `deploy-service.sh:225`                                                                                                                    | 90%        | Open               |
| F15 | P1       | Traefik `v3.7.1`, Authelia `4.39`, and wg-easy `15` are unverified against upstream availability and compatibility.       | `cloud-config:437,569,714`                                                                                                                 | Unverified | Needs verification |
| F16 | P1       | The decision record and work plan were gitignored through the `tmp/` pattern.                                             | `.gitignore:31`; moved to `docs/process/component-research.md` and `docs/process/archive/work-plan.md` on 2026-11-12; tracked in `4a0a2ff` | 100%       | Fixed              |
| F17 | P1       | `oci-cli` installation via plain `dnf install` assumes an enabled repository that may not be present on OL9.              | `cloud-config:576`                                                                                                                         | 60%        | Needs verification |

## P2: governance and completeness

| ID  | Severity | Finding                                                                                                                | Evidence                                       | Confidence | Status |
| --- | -------- | ---------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- | ---------- | ------ |
| F18 | P2       | Goals exist only as a draft; no confirmed goal contract or definition of done.                                         | `docs/goals.md`, `docs/process/goals-audit.md` | 100%       | Open   |
| F19 | P2       | No deployment evidence exists, while README claims production readiness.                                               | `README.md:3`, no test artifacts               | 100%       | Open   |
| F20 | P2       | Working tree is inconsistent: tracked deletion of `docs/work-plan.md`, modified `.gitignore`, planning docs untracked. | `4a0a2ff`; `git status` clean                  | 100%       | Fixed  |
| F21 | P2       | No IaC for OCI infrastructure, Vault, IAM, or DNS. All prerequisites are manual.                                       | `stack-guide.md` section 13.8                  | 100%       | Open   |
| F22 | P2       | Backup is documented but not implemented. No Restic, timer, bucket, or fourth secret.                                  | `stack-guide.md` section 13.7                  | 100%       | Open   |
| F23 | P2       | Empty placeholders in `configs/`, `scripts/deploy/`, `docs/`, and `Makefile` imply structure that does not exist.      | File sizes                                     | 100%       | Open   |
| F24 | P2       | The README, `.env.example`, and `CONTRIBUTING.md` reference legacy root-level paths.                                   | `README.md:53-59`, `CONTRIBUTING.md`           | 100%       | Open   |

## Runtime questions to answer with evidence

These are not findings yet. They are tests that must run in a disposable environment.

| ID  | Question                                                                         | Method                                                     |
| --- | -------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| Q1  | Does Authelia start and persist its SQLite data?                                 | First boot, `journalctl -u authelia`, file ownership check |
| Q2  | Does wg-easy create peer state and pass traffic?                                 | First peer, handshake, ping `10.0.0.1`                     |
| Q3  | Does Cockpit accept proxied WebSocket connections?                               | Browser through Traefik, terminal session                  |
| Q4  | Are certificates issued for every hostname?                                      | `acme.json`, `openssl s_client`                            |
| Q5  | Does the block volume survive reboot and reattachment?                           | Reboot and replacement drill                               |
| Q6  | Does a second cloud-init run remain idempotent?                                  | Rerun modules and compare state                            |
| Q7  | Does the instance boot without a block volume attached, and does it fail safely? | Negative test                                              |
