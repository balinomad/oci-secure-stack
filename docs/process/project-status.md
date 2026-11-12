---
name: "Project Status Report"
description: |
  Static assessment of repository state, documentation state, implementation status, risks, and explicit non-claims.
status: active
version: 1.0
updated: 2026-11-12
---

# Project Status Report

Baseline: commit `2c1ae2c`, 2026-11-12.\
Method: static analysis of repository files. No OCI deployment has been executed.

## Verdict

The documentation tree is consolidated. The implementation is still unproven.

- The design record, guides, reference, and decision records now have one entry point each.
- The implementation is a single 771-line cloud-init template plus two scripts. Neither has deployment evidence.
- At least six strategic decisions still contradict the implementation.
- The goals are now stated in the architecture record but are not formally confirmed.
- The legacy documentation tree is migrated in draft form and retained until the migration is verified.

The only executable artifact is `infra/cloud-init/cloud-config.example.yaml`. Until it is tested, it is also the only source of ground truth about behaviour, which is the opposite of the intended governance model.

## Report scope

This report covers the project defined in `docs/architecture.md`. It records repository state, implementation status, and risks. It does not define goals, principles, or decisions.

## Repository state

| Area                   | State                                | Evidence                                             |
| ---------------------- | ------------------------------------ | ---------------------------------------------------- |
| Cloud-init template    | Real, 771 lines                      | `infra/cloud-init/cloud-config.example.yaml`         |
| Verification script    | Real, 298 lines, syntactically valid | `scripts/host/verify-stack.sh`                       |
| Deployment script      | Real, 240 lines, syntactically valid | `scripts/host/deploy-service.sh`                     |
| Modular deploy scripts | Empty, 7 files                       | `scripts/host/deploy/00-06`                          |
| Extracted configs      | Empty, 4 files                       | `configs/`                                           |
| Makefile               | Empty                                | `Makefile`                                           |
| Documentation          | Consolidated, no empty placeholders  | `README.md`, `docs/`                                 |
| Planning and research  | Substantive, kept as evidence        | `tmp/unverified/`, `tmp/legacy/work-plan.md`         |
| CI                     | None                                 | `.github/workflows` empty                            |
| Changelog or releases  | None                                 | No `CHANGELOG.md`, no tags                           |

## Git state

- Branch `master` tracks `origin/master`, remote `github.com/balinomad/oci-secure-stack`.
- Last commit before the documentation consolidation: `2c1ae2c`, 2026-11-12.
- The consolidation is uncommitted until the next commit.
- Research and planning files are kept under `tmp/unverified/` and `tmp/legacy/`.
- Legacy source documents are kept under `tmp/legacy/` until the migration is verified.

## Documentation state

| Document                   | Role                                                         | Status                        |
| -------------------------- | ------------------------------------------------------------ | ----------------------------- |
| `README.md`                | Front door and documentation map                             | Current, design unverified    |
| `docs/architecture.md`     | Sole design record                                           | Draft, needs confirmation     |
| `docs/decisions/`          | Decision records                                             | Draft                         |
| `docs/guides/`             | Deploy, operate, extend                                      | Draft, derived from legacy    |
| `docs/reference/`          | Exact configuration facts                                    | Draft, derived from legacy    |
| `docs/process/`            | Living status, issue log, delivery plan, acceptance criteria | Active                        |
| `tmp/unverified/`          | Point-in-time audits and migration map                       | Historical evidence           |
| `tmp/legacy/work-plan.md`  | Legacy implementation work plan                              | Unverified, not authoritative |

The documentation has no empty placeholders. The guides describe the intended design; they do not prove deployment behaviour.

## Implementation status

Implemented in the monolith:

- Users, groups, packages, Traefik static and dynamic configuration, Cockpit route, logrotate
- Authelia configuration template and Argon2 user bootstrap
- Traefik hardened systemd unit
- Authelia and wg-easy system units using rootful Podman
- Block volume detection, XFS formatting, UUID fstab mount, `/data` layout, symlinks
- OCI Vault secret fetch with Instance Principal
- SELinux contexts, firewalld rules, IP forwarding, persistent journal
- Architecture-aware Traefik download
- Manifest replay for application services after VM replacement
- Verification and application deployment scripts

Not implemented:

- Terraform or any IaC for VCN, subnet, instance, block volume, Vault, IAM, DNS
- Restic backup, timer, and fourth Vault secret
- PCP Prometheus export
- Health checks, alerting, certificate expiry monitoring
- CI, linting, schema validation, or tests
- Changelog, releases, version-pin verification
- Any deployment evidence

## Principal risks

| Risk                                                                                  | Impact                            | Confidence       |
| ------------------------------------------------------------------------------------- | --------------------------------- | ---------------- |
| The first deployment fails at Authelia because of file ownership versus container UID | High, boot blocker                | 70% until tested |
| A failed block volume mount silently produces an ephemeral deployment                 | High, data loss on VM replacement | 100% from code   |
| The implemented admin exposure model bypasses the stated security model               | High, security                    | 90%              |
| The refactor proceeds before behaviour is proven                                      | Medium, rework                    | 85%              |
| Version pins are unavailable or incompatible                                          | Medium, boot blocker              | Unverified       |
| The consolidated guides are mistaken for proof of deployment                          | Medium, false confidence          | 80%              |

## Explicit non-claims

This report does not claim:

- That any service starts correctly on OCI
- That certificates are issued
- That the VPN works
- That Authelia authentication works
- That any finding marked unverified is a confirmed runtime failure

Those claims require a disposable deployment and recorded evidence. The open questions are listed in `docs/process/issue-log.md`.
