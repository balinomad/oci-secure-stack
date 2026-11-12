---
name: "Status Report"
description: |
  Static assessment of repository state, documentation status, implementation status, risks, and explicit non-claims.
status: active
version: 1.0
updated: 2026-11-12
---

# Status Report

Baseline: commit `7fbb538`, 2026-09-04, plus uncommitted working tree changes Method: static analysis. No OCI deployment has been executed.

## Verdict

The project is not close to a deployable v1, but most of the design thinking exists.

- The design layer is strong: architecture, access model, threat model, Traefik detail, application integration contract, and testing strategy.
- The implementation layer is a single 771-line cloud-init template plus two scripts. Neither has deployment evidence.
- The current repository structure is mostly empty placeholders.
- Strategic decisions and implementation contradict each other in at least six places.
- Goals exist only as a draft contract, and decision records are not tracked in git.

The only executable artifact is `infra/cloud-init/cloud-config.example.yaml`. Until it is tested, it is also the only source of ground truth about behaviour, which is the opposite of the intended governance model.

## Report scope

This report covers the project defined in `docs/goals.md`. It records repository state, documentation status, implementation status, and risks. It does not define goals, principles, or decisions.

## Repository state

| Area                   | State                                 | Evidence                                                                  |
| ---------------------- | ------------------------------------- | ------------------------------------------------------------------------- |
| Cloud-init template    | Real, 771 lines                       | `infra/cloud-init/cloud-config.example.yaml`                              |
| Verification script    | Real, 298 lines, syntactically valid  | `scripts/verify/verify-stack.sh`                                          |
| Deployment script      | Real, 240 lines, syntactically valid  | `scripts/utils/deploy-service.sh`                                         |
| Modular deploy scripts | Empty, 7 files                        | `scripts/deploy/00-06`                                                    |
| Extracted configs      | Empty, 4 files                        | `configs/`                                                                |
| Makefile               | Empty                                 | `Makefile`                                                                |
| New documentation tree | Partial, placeholders plus draft ADRs | `docs/architecture.md`, `docs/components/`, `docs/decisions/`             |
| Legacy documentation   | Substantive, about 120 KB             | `docs/legacy/`                                                            |
| Planning and research  | Substantive, moved out of `tmp/`      | `docs/process/component-research.md`, `docs/process/archive/work-plan.md` |
| CI                     | None                                  | `.github/workflows` empty                                                 |
| Changelog or releases  | None                                  | No `CHANGELOG.md`, no tags                                                |

## Git state

- Branch `master` tracks `origin/master`, remote `github.com/balinomad/oci-secure-stack`.
- Last commit: `7fbb538`, 2026-09-04. The project has been dormant for about ten weeks.
- Working tree: `.gitignore` modified, `docs/work-plan.md` deleted but still tracked at HEAD.
- The research and planning files were moved out of `docs/tmp/` on 2026-11-12 to `docs/process/component-research.md` and `docs/process/archive/work-plan.md`.
- They are no longer ignored by `.gitignore:31`, but they remain untracked until the next commit. The clean-clone risk is not cleared until that commit.

## Documentation status

| Document                               | Status                              | Authority                          |
| -------------------------------------- | ----------------------------------- | ---------------------------------- |
| `README.md`                            | Stale, claims production readiness  | Low until claims are proven        |
| `docs/legacy/stack-guide.md`           | Complete, detailed                  | High for intent, partly superseded |
| `docs/legacy/traefik-guide.md`         | Complete                            | High for Traefik detail            |
| `docs/legacy/app-integration-guide.md` | Complete                            | High for app contract              |
| `docs/legacy/testing-guide.md`         | Complete                            | Useful strategy, never executed    |
| `docs/process/component-research.md`   | Complete Phase 2 research           | Research evidence, draft           |
| `docs/process/archive/work-plan.md`    | Superseded                          | Historical, not authoritative      |
| New docs tree                          | Partial placeholders and draft ADRs | Mixed, not final                   |

Documentation defects:

- README, `.env.example`, `CONTRIBUTING.md`, and the cloud-init header reference root-level paths that no longer exist.
- README calls the stack production-ready without test evidence.
- The archived work plan marks Phase 2 as pending even though `docs/process/component-research.md` contains the research.
- The security model in README is contradicted by the implemented dashboard, metrics, and Cockpit paths.

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
| The decision record is lost because it is gitignored                                  | High, governance                  | 100%             |
| The refactor proceeds before behaviour is proven                                      | Medium, rework                    | 85%              |
| Version pins are unavailable or incompatible                                          | Medium, boot blocker              | Unverified       |

## Explicit non-claims

This report does not claim:

- That any service starts correctly on OCI
- That certificates are issued
- That the VPN works
- That Authelia authentication works
- That any finding marked unverified is a confirmed runtime failure

Those claims require the disposable deployment in the resumption plan.
