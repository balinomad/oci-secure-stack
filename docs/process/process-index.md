---
name: "Process Record"
description: |
  Index and maintenance rules for the project process record, including the status legend and evidence rules.
status: active
version: 1.4
updated: 2026-11-14
---

# Process Record

Purpose: record how the project is being worked, what is done, what is broken, and what happens next. This directory is process documentation, not project definition.

Project-defining material lives outside this directory:

- Purpose, goals, principles, architecture, and security model: `docs/architecture.md`
- Strategic decisions: `docs/decisions/`
- Deployment procedure: `docs/guides/getting-started.md`
- Operations runbook: `docs/guides/operations.md`
- Application integration: `docs/guides/adding-apps.md`
- Infrastructure reference: `docs/reference/infrastructure.md`
- Traefik reference: `docs/reference/traefik.md`
- Application manifest reference: `docs/reference/application-manifest.md`

## Implementation sources

| Role                   | Path                                         |
| ---------------------- | -------------------------------------------- |
| Stack implementation   | `infra/cloud-init/cloud-config.example.yaml` |
| Configuration source   | `infra/manifest.yaml`                        |
| Staged runtime assets  | `infra/runtime/`                             |
| Configuration renderer | `tools/render-config.sh`                     |
| Host verification      | `infra/host/verify-stack.sh`                 |
| Monitoring deployment  | `infra/host/07-monitoring.sh`                |
| Alerting deployment    | `infra/host/08-alerting.sh`                  |
| Application deployment | `infra/host/deploy-service.sh`               |
| Documentation audit    | `tools/audit-docs.sh`                        |

Baseline: commit `2c1ae2c`, 2026-11-12.\
Method: static analysis of repository files. No OCI deployment has been executed.

## Document map

| File                                                                          | Purpose                                                                  | Update when                               |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------- |
| [docs/process/project-status.md](/docs/process/project-status.md)             | Repository, documentation, and implementation status                     | A major milestone is reached              |
| [docs/process/document-conventions.md](/docs/process/document-conventions.md) | Document versioning, status, placement, and commit conventions           | A convention is added or changed          |
| [docs/process/issue-log.md](/docs/process/issue-log.md)                       | Stable, numbered issues with evidence and status                         | An issue is found, fixed, or reclassified |
| [docs/process/delivery-plan.md](/docs/process/delivery-plan.md)               | Decision-first delivery plan, phases, gates, estimates, and next actions | A phase starts or closes                  |
| [docs/process/acceptance-criteria.md](/docs/process/acceptance-criteria.md)   | Acceptance criteria with recorded evidence                               | A criterion is proven or changed          |

## Status legend

| Label        | Meaning                                                     |
| ------------ | ----------------------------------------------------------- |
| Proven       | Verified by execution or direct artifact evidence           |
| Claimed      | Stated in documentation but not verified                    |
| Contradicted | Documentation and implementation disagree                   |
| Unknown      | Not enough evidence                                         |
| Not started  | No implementation exists                                    |
| Partial      | An implementation exists, but the contract is not fully met |

## Evidence rules

1. A claim is `Claimed` until it has an execution log, a test result, or a direct file reference.
2. A decision is authoritative only when it is tracked in git and has a decision ID.
3. Findings keep their original IDs. Do not renumber. Mark them `Fixed` with the commit or test evidence.
4. Do not update a finding to `Fixed` because the code looks correct. Update it after a deployment test passes.
5. Do not delete a record to hide an unresolved problem. Move superseded material to `tmp/unverified/` and mark its status.

## Documentation state

The repository has one front door, one design record, and one process record. No empty documentation placeholders remain. Deployment behaviour is still unproven.
