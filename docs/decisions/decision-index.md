---
name: "Decision Records"
description: |
  Index of architecture decision records for the OCI secure stack.
status: active
version: 1.2
updated: 2026-11-14
---

# Decision Records

Each record states the context, the affected paths, the current text or behavior, and the contradiction. It also states the options, the consequence of each option, the recommendation, the decision, and the consequences. A decision is authoritative only after it is tracked in git and confirmed by the project owner (the repository maintainer). All current records are drafts.

| ID      | Title                                | Status | File                                                                               |
| ------- | ------------------------------------ | ------ | ---------------------------------------------------------------------------------- |
| ADR-001 | Management plane exposure model      | Draft  | [001-exposure-model.md](001-exposure-model.md)                                     |
| ADR-002 | Authelia runtime and file ownership  | Draft  | [002-authelia-runtime.md](002-authelia-runtime.md)                                 |
| ADR-003 | Metrics architecture                 | Draft  | [003-metrics-architecture.md](003-metrics-architecture.md)                         |
| ADR-004 | Persistence and mount failure policy | Draft  | [004-persistence.md](004-persistence.md)                                           |
| ADR-005 | Application container contract       | Draft  | [005-application-contract.md](005-application-contract.md)                         |
| ADR-006 | Backup and recovery scope            | Draft  | [006-backup-and-recovery-scope.md](006-backup-and-recovery-scope.md)               |
| ADR-007 | OCI provisioning method              | Draft  | [007-oci-provisioning-method.md](007-oci-provisioning-method.md)                   |
| ADR-008 | Traefik runtime                      | Draft  | [008-traefik-runtime.md](008-traefik-runtime.md)                                   |
| ADR-009 | Infrastructure container runtime     | Draft  | [009-infrastructure-container-runtime.md](009-infrastructure-container-runtime.md) |
| ADR-010 | Local monitoring UI and history      | Draft  | [010-monitoring-presentation.md](010-monitoring-presentation.md)                   |

ADR-006 and ADR-007 are draft. ADR-009 and ADR-010 are decided in content and remain draft until committed and confirmed.

## Open decision questions

| ID  | Question | Target decision |
| --- | -------- | --------------- |

## When to write a decision

Write a decision when a choice changes architecture, security, data durability, or deployment method. Write a decision when a choice changes a contract that other documents depend on. Do not write a decision for a reversible implementation detail.

## When to supersede a decision

Do not edit a confirmed decision to reverse it. Write a new decision, mark the old one `superseded`, and update the index. A draft may be revised directly.

## Related documents

- Architecture and decision index: `docs/architecture.md`
- Issue log: `docs/process/issue-log.md`
- Delivery plan: `docs/process/delivery-plan.md`
