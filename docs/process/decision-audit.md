---
name: "Strategic Decision Audit"
description: |
  Audits existing strategic decisions against the project goals and records implementation alignment, conflicts, and decisions that still need confirmation.
status: active
version: 1.0
updated: 2026-11-12
---

# Strategic Decision Audit

This audit checks what has been decided on the strategic level and whether each decision is coherent with the reconstructed goals in `../goals.md`.

The decisions themselves belong in `docs/decisions/` as tracked ADRs. This document only reviews implementation alignment.

## Authority hierarchy today

Draft ADRs now exist under `docs/decisions/` and are committed in `4a0a2ff`, but none is confirmed. No decision is formally authoritative yet.

Current effective order, from strongest to weakest:

1. `docs/decisions/*.md`: draft ADRs, committed in `4a0a2ff`, not confirmed
2. `docs/process/component-research.md`: research evidence behind the draft ADRs
3. `docs/process/archive/work-plan.md`: historical plan, superseded
4. `docs/legacy/*.md`: substantive but partly superseded
5. `README.md`: claims that contradict the newer material
6. `infra/cloud-init/cloud-config.example.yaml`: implementation, which remains the de facto contract

This inversion is the central governance problem. The implementation currently overrides the decisions because it is the only executable artifact.

## Decision register

Status values: Aligned, Partial, Contradicted, Not started, Unverified.

| ID  | Decision                                                                      | Source                                                                                      | Implementation                                                             | Cohesion                     | Action                                              |
| --- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- | ---------------------------- | --------------------------------------------------- |
| D1  | Single OCI Oracle Linux 9 VM runs a hardened admin stack                      | `README.md`, `stack-guide.md`                                                               | Implemented as one cloud-init template                                     | Aligned with G1              | Confirm as goal                                     |
| D2  | Admin access is VPN-first, then Authelia                                      | `README.md`, `stack-guide.md` sections 3 and 4                                              | Routers use `admin-chain`                                                  | Partial, bypasses exist      | Fix F9, F10                                         |
| D3  | Traefik dashboard and metrics are localhost-only, accessed via SSH forwarding | `docs/process/archive/work-plan.md` Phase 1, `docs/process/component-research.md` section 4 | Still routed as `traefik.` and `metrics.` hostnames                        | Contradicted                 | Remove routers or reverse the decision explicitly   |
| D4  | Traefik runs as a native binary with a hardened systemd unit                  | `docs/process/component-research.md` section 4, `traefik-guide.md`                          | Implemented                                                                | Aligned                      | Keep                                                |
| D5  | Authelia prefers rootless Podman                                              | `docs/process/component-research.md` section 3                                              | Rootful `podman run` system unit                                           | Contradicted                 | Confirm rootful for v1 or implement rootless        |
| D6  | Authelia uses file auth backend and SQLite on `/data`                         | `docs/process/component-research.md` section 3                                              | Implemented structurally                                                   | Partial, ownership risk F1   | Prove first boot                                    |
| D7  | Cockpit uses PAM after Authelia, and binds to localhost                       | `docs/process/component-research.md` section 1                                              | Route exists, but no localhost bind and a direct firewall rule exists      | Contradicted                 | Implement bind override, remove direct rule         |
| D8  | Host metrics use PCP native export, no Prometheus server                      | `docs/process/component-research.md` section 2                                              | PCP installed, no export configured, metrics route points at Traefik       | Contradicted                 | Implement `pmproxy` or drop PCP from v1             |
| D9  | All persistent state lives on the block volume at `/data`                     | `README.md`, `stack-guide.md`, `docs/process/component-research.md` section 5               | Layout implemented, mount failure is non-fatal                             | Partial, high risk F2 and F3 | Hard-fail and validate filesystem                   |
| D10 | Services run under dedicated non-login users, not `opc`                       | `docs/process/component-research.md` section 5                                              | Traefik uses a dedicated user; Authelia and wg-easy are rootful containers | Partial                      | Confirm per-component model                         |
| D11 | Application containers use Podman Quadlet                                     | `stack-guide.md` section 12, `app-integration-guide.md`                                     | Apps use Quadlet via `deploy-service.sh`; infrastructure containers do not | Partial                      | Decide whether infrastructure must also use Quadlet |
| D12 | Secrets come from OCI Vault, never from the template                          | `README.md`, `stack-guide.md` section 7                                                     | Three secrets fetched at boot                                              | Aligned, but no fail-fast F4 | Hard-fail on fetch error                            |
| D13 | Application secrets are not stored in manifests                               | `app-integration-guide.md` section 9                                                        | `deploy-service.sh` writes `--env` values into a world-readable manifest   | Contradicted, F11            | Fix manifest permissions and secret handling        |
| D14 | Backup uses Restic to OCI Object Storage                                      | `stack-guide.md` section 13.7                                                               | Not implemented                                                            | Not started                  | Confirm v1 scope                                    |
| D15 | OCI infrastructure should eventually use Terraform                            | `stack-guide.md` section 13.8                                                               | Not implemented                                                            | Not started, not committed   | Confirm v1 scope                                    |
| D16 | Documentation is split into architecture, component, and guide documents      | `TODO.md`, `docs/process/archive/work-plan.md`                                              | New tree exists as empty files                                             | Not started                  | Populate after behaviour is proven                  |
| D17 | Deployment scripts are idempotent                                             | `TODO.md`                                                                                   | Some blocks are idempotent, some are not; unverified                       | Unverified                   | Prove with rerun test                               |
| D18 | The repository is named `oci-secure-stack`                                    | `TODO.md`                                                                                   | Remote and README use the name                                             | Aligned                      | Keep                                                |
| D19 | The repository contains no application source code                            | `TODO.md`                                                                                   | True today                                                                 | Aligned with G7              | Keep                                                |
| D20 | Verification is automated by `verify-stack.sh`                                | `stack-guide.md` section 11                                                                 | Script exists, one check is invalid F5                                     | Partial                      | Fix and extend                                      |

## Decision conflicts with goals

| Goal                       | Conflicting decisions | Effect                                                                        |
| -------------------------- | --------------------- | ----------------------------------------------------------------------------- |
| G2 admin security          | D3, D7, D8, D9, D10   | Multiple admin paths bypass the intended gate, or the gate is not implemented |
| G3 persistent state        | D9                    | A mount failure silently degrades to ephemeral state                          |
| G4 reproducible deployment | D12, D15, D17         | Manual prerequisites, no IaC, unproven idempotency                            |
| G5 documentation           | D16                   | Documentation is not started and existing docs are stale                      |
| G6 application hosting     | D13                   | Secret exposure in deployment manifests                                       |

## Decisions that need confirmation

These are strategic. They should be resolved before code changes.

| ID  | Question                                                                        | Recommended default                              | Trade-off if reversed                                                               |
| --- | ------------------------------------------------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| Q1  | Is the dashboard and metrics exposure localhost-only or behind the admin chain? | Localhost-only, SSH tunnel                       | Behind the chain is more convenient but adds an internet-facing surface             |
| Q2  | Is Authelia rootful or rootless for v1?                                         | Rootful for v1, rootless as a follow-up          | Rootless is stronger but needs user provisioning, lingering, and Quadlet user units |
| Q3  | Is host metrics required in v1?                                                 | Traefik metrics only for v1; PCP export in v1.1  | Implementing PCP now adds a second metrics stack and another sensitive surface      |
| Q4  | Is Restic backup in v1?                                                         | Yes if the block volume holds irreplaceable data | Deferring risks total state loss                                                    |
| Q5  | Are OCI prerequisites manual or Terraform-managed?                              | Manual for v1, Terraform as v1.1                 | Manual creates drift and weakens the reproducible-deployment goal                   |
| Q6  | Are infrastructure containers required to use Quadlet?                          | Yes, for consistency                             | Plain systemd units work but contradict D11                                         |
| Q7  | Is the goal a working personal deployment, a reusable public template, or both? | Working deployment first, template second        | A public template raises documentation and portability requirements                 |

## Required governance change

1. Done: `docs/decisions/` contains draft ADR-001 to ADR-005 and ADR-008.
2. Done: research moved to `docs/process/component-research.md` and extracted into ADRs.
3. Mark superseded statements in legacy documents explicitly. Not done.
4. Require every implementation change to reference a decision ID or a finding ID.
5. Do not treat the implementation as the contract. The ADR is the contract; the deployment is the evidence.

Confidence in this audit: high for the existence and content of decisions (95%). Confidence in runtime consequences: medium (70%) until deployment tests confirm findings F1, F5, and F8.
