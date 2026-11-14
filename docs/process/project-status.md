---
name: "Project Status Report"
description: |
  Static assessment of repository state, documentation state, implementation status, risks, and explicit non-claims.
status: active
version: 1.4
updated: 2026-11-14
---

# Project Status Report

Baseline: commit `2c1ae2c`, 2026-11-12.\
Method: static analysis of repository files. No OCI deployment has been executed.

## Verdict

The documentation tree is consolidated. The implementation is still unproven.

- The design record, guides, reference, and decision records now have one entry point each.
- The implementation is a cloud-init template, a configuration source tree, and a set of deployment and verification scripts. None has deployment evidence.
- Several strategic decisions still contradict the implementation.
- The goals are now stated in the architecture record but are not formally confirmed.
- The legacy documentation tree is migrated in draft form and retained until the migration is verified.

The cloud-init template and the configuration source tree define the base host deployment. Until they are tested, they are also the only source of ground truth about base host behaviour, which is the opposite of the intended governance model.

## Report scope

This report covers the project defined in `docs/architecture.md`. It records repository state, implementation status, and risks. It does not define goals, principles, or decisions.

## Repository state

| Area                   | State                               | Evidence                                                                            |
| ---------------------- | ----------------------------------- | ----------------------------------------------------------------------------------- |
| Cloud-init template    | Template with generated markers     | `infra/cloud-init/cloud-config.example.yaml`                                        |
| Verification script    | Non-empty, shellcheck clean         | `infra/host/verify-stack.sh`; `shellcheck infra/host/verify-stack.sh`               |
| Deployment script      | Non-empty, shellcheck clean         | `infra/host/deploy-service.sh`; `shellcheck infra/host/deploy-service.sh`           |
| Modular deploy scripts | Partial                             | `infra/host/00-06` empty; `infra/host/07-monitoring.sh` and `08-alerting.sh` active |
| Extracted configs      | Populated, manifest and renderer    | `infra/manifest.yaml`; `tools/render-config.sh --check`                             |
| Documentation          | Consolidated, no empty placeholders | `README.md`, `docs/`                                                                |
| Planning and research  | Substantive, kept as evidence       | `tmp/unverified/`, `tmp/legacy/work-plan.md`                                        |
| CI                     | None                                | `.github/workflows` empty                                                           |
| Changelog or releases  | None                                | No `CHANGELOG.md`, no tags                                                          |

## Git state

- Branch `master` tracks `origin/master`, remote `github.com/balinomad/oci-secure-stack`.
- Last commit before the documentation consolidation: `2c1ae2c`, 2026-11-12.
- The consolidation is uncommitted until the next commit.
- Research and planning files are kept under `tmp/unverified/` and `tmp/legacy/`.
- Legacy source documents are kept under `tmp/legacy/` until the migration is verified.

## Documentation state

| Document                  | Role                                                         | Status                        |
| ------------------------- | ------------------------------------------------------------ | ----------------------------- |
| `README.md`               | Front door and documentation map                             | Current, design unverified    |
| `docs/architecture.md`    | Sole design record                                           | Draft, needs confirmation     |
| `docs/decisions/`         | Decision records                                             | Draft                         |
| `docs/guides/`            | Deploy, operate, extend                                      | Draft, derived from legacy    |
| `docs/reference/`         | Exact configuration facts                                    | Draft, derived from legacy    |
| `docs/process/`           | Living status, issue log, delivery plan, acceptance criteria | Active                        |
| `tmp/unverified/`         | Point-in-time audits and migration map                       | Historical evidence           |
| `tmp/legacy/work-plan.md` | Legacy implementation work plan                              | Unverified, not authoritative |

The documentation has no empty placeholders. The guides describe the intended design; they do not prove deployment behaviour.

## Implementation status

Implemented in the monolith:

- Users, groups, packages, Traefik static and dynamic configuration, Cockpit route, logrotate
- Authelia configuration template and Argon2 user bootstrap
- Traefik hardened systemd unit
- Authelia rootless Quadlet user unit and wg-easy rootful Quadlet system unit in a user namespace
- Block volume detection, XFS formatting, UUID fstab mount, `/data` layout, symlinks
- OCI Vault secret fetch with Instance Principal
- SELinux contexts, firewalld rules, IP forwarding, persistent journal
- Architecture-aware Traefik download
- Manifest replay for application services after VM replacement
- Verification and application deployment scripts
- PCP export through `pmproxy`, the Podman PMDA, and the OpenMetrics PMDA
- Optional Grafana and Valkey monitoring profiles, statically configured
- Alert delivery through PCP `pmie`, systemd failure hooks, an HTTPS webhook, and an external heartbeat, statically configured

Not implemented:

- Terraform or any IaC for VCN, subnet, instance, block volume, Vault, IAM, DNS
- Restic backup, timer, and backup secret
- Health checks beyond the configured service checks and certificate expiry timer
- CI, linting, schema validation, or tests
- Changelog, releases, version-pin verification
- Any deployment evidence

## Principal risks

| Risk                                                                                    | Impact                            | Confidence       |
| --------------------------------------------------------------------------------------- | --------------------------------- | ---------------- |
| The first deployment fails at Authelia because of rootless ownership or SELinux relabel | High, boot blocker                | 70% until tested |
| A failed block volume mount silently produces an ephemeral deployment                   | High, data loss on VM replacement | 100% from code   |
| The implemented admin exposure model bypasses the stated security model                 | High, security                    | 90%              |
| The refactor proceeds before behaviour is proven                                        | Medium, rework                    | 85%              |
| Version pins are unavailable or incompatible                                            | Medium, boot blocker              | Unverified       |
| The consolidated guides are mistaken for proof of deployment                            | Medium, false confidence          | 80%              |
| Alert delivery is configured but unproven                                               | Medium, missed failure            | 90% from code    |

## Explicit non-claims

This report does not claim:

- That any service starts correctly on OCI
- That certificates are issued
- That the VPN works
- That Authelia authentication works
- That alert delivery has been tested
- That any finding marked unverified is a confirmed runtime failure

Those claims require a disposable deployment and recorded evidence. The open questions are listed in `docs/process/issue-log.md`.
