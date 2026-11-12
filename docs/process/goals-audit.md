---
name: "Goals Audit"
description: |
  Evidence trail for goal discovery, reconstructed goals, conflicts, and unresolved scope questions. The normative goal contract is docs/goals.md.
status: active
version: 1.0
updated: 2026-11-12
---

# Goals Audit

This is a process document. It records what was found in the repository, not what the project aims to be. The normative goal contract is `docs/goals.md`; project principles are in `docs/principles.md`.

Method: static analysis of repository files. No OCI deployment has been executed.

## Direct answer

There are no formally stated goals in the repository as of the baseline commit.

No file contains a goal statement, success criteria, scope boundary, or definition of done. The closest material is:

- `README.md`: marketing claims such as "production-ready" and "replaceable in under 10 minutes"
- `TODO.md`: a mixed list of naming, documentation, and tooling tasks
- `docs/process/archive/work-plan.md`: a task plan, not a goal statement
- `docs/process/component-research.md`: architectural constraints and component decisions
- `SECURITY.md`: security principles, not goals

These are inputs, not a goal contract. They cannot be used to decide whether the project is finished.

Confidence: 100% that no explicit goals document existed at the baseline. The reconstructed goals below are inferred and must be confirmed.

## Reconstructed implicit goals

| ID  | Goal                                                                 | Source                                                                          | Proposed acceptance criterion                                                                                        | Status                                |
| --- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| G1  | Deploy a hardened admin stack on one OCI Oracle Linux 9 VM           | `README.md`, `docs/legacy/stack-guide.md`                                       | A clean instance reaches `cloud-init status: done` and every required service is active with no unhandled errors     | Claimed, unproven                     |
| G2  | Restrict all admin access to WireGuard plus Authelia MFA             | `README.md`, `docs/legacy/stack-guide.md`, `SECURITY.md`                        | Admin URLs return 403 without VPN and require password plus TOTP over VPN; no admin path bypasses Authelia           | Contradicted by F6, F7, F9, F10       |
| G3  | Keep the VM disposable and all state persistent                      | `README.md`, `docs/legacy/stack-guide.md`, `docs/process/component-research.md` | Replacing the instance preserves certificates, Authelia users and sessions, WireGuard peers, and app data on `/data` | Contradicted by F2 and F3             |
| G4  | Make deployment reproducible from the repository                     | `README.md`, `TODO.md`                                                          | A new operator can render the template, deploy, and verify from tracked files alone                                  | Claimed, unproven                     |
| G5  | Provide clear documentation for operators and application developers | `TODO.md`, `docs/process/legacy-migration-map.md`                               | A new operator can deploy without reading legacy documents; docs match tested behaviour                              | Not started                           |
| G6  | Host additional applications via Podman Quadlet                      | `README.md`, `docs/legacy/app-integration-guide.md`                             | A new application can be deployed with two files, persists on `/data`, and is reconstructed after VM replacement     | Partial, security defects F11 and F13 |
| G7  | Keep the repository free of application source code                  | `TODO.md`                                                                       | The repository contains infrastructure, configuration, and documentation only                                        | Aligned, currently true               |

## Goal conflicts

| Conflict                                                                            | Consequence                                                                           |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| "Production-ready" claim versus no deployment evidence                              | The project cannot be assessed as complete. Any release claim is unsupported.         |
| G2 versus the direct Cockpit firewall rule and public dashboard and metrics routers | The stated security model is not the implemented model.                               |
| G3 versus non-fatal `/data` mount handling                                          | A deployment can silently run with ephemeral state and lose all state on replacement. |
| G5 versus 14 empty documentation files and stale README paths                       | The documentation structure exists only as placeholders.                              |
| G6 versus secret-bearing world-readable manifests                                   | Application hosting can leak credentials.                                             |

## Scope questions still unanswered

1. Is the target a greenfield deployment or an existing environment with data?
2. Is "production" a single-user personal stack, or does it need multi-user operations?
3. Is backup and restore part of v1, or a follow-up?
4. Is host metrics part of v1, or is Traefik metrics sufficient?
5. Is Terraform for OCI infrastructure part of v1, or a follow-up?
6. Is the desired outcome a working deployment, a reusable public template, or both?

These answers change the acceptance criteria and the plan. They must be resolved before implementation resumes.

## Disposition

The inferred goals have been promoted into `docs/goals.md` as a draft contract. The principles have been promoted into `docs/principles.md`. The tables above remain here as the evidence trail and are not normative.
