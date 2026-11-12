---
name: "Process Record"
description: |
  Index and maintenance rules for the project process record, including the status legend and evidence rules.
status: active
version: 1.0
updated: 2026-11-12
---

# Process Record

Purpose: record how the project is being worked, what is done, what is broken, and what happens next. This directory is process documentation, not project definition.

Project-defining material lives outside this directory:

- Goals and scope: `docs/goals.md`
- Project principles: `docs/principles.md`
- Strategic decisions: `docs/decisions/`
- Architecture and component documentation: `docs/architecture.md`, `docs/components/`
- Operator guides: `docs/guides/`

Baseline: commit `4a0a2ff`.\
Method: static analysis of repository files. No OCI deployment has been executed.

## Document map

| File                      | Purpose                                                                     | Update when                                      |
| ------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------ |
| `status-report.md`        | Repository, documentation, and implementation status                        | A major milestone is reached                     |
| `goals-audit.md`          | Evidence trail for goal discovery, conflicts, and unresolved scope          | A goal is confirmed, added, or retired           |
| `document-conventions.md` | Document versioning and commit conventions                                  | A convention is added or changed                 |
| `findings-register.md`    | Stable, numbered findings with evidence and status                          | A finding is found, fixed, or reclassified       |
| `decision-audit.md`       | Reviews whether strategic decisions are implemented and coherent with goals | A decision is confirmed, changed, or implemented |
| `component-research.md`   | Component research evidence behind the ADR set                              | New research is added or a decision is extracted |
| `legacy-migration-map.md` | Legacy content migration mapping                                            | A legacy section is migrated or the map changes  |
| `resumption-plan.md`      | Decision-first plan, phases, gates, estimates                               | A phase starts or closes                         |
| `deployment-checklist.md` | Acceptance tracking for a proper deployment                                 | A criterion is proven or changed                 |
| `archive/work-plan.md`    | Superseded historical work plan                                             | Never; retained for audit                        |

## Status legend

| Label        | Meaning                                                       |
| ------------ | ------------------------------------------------------------- |
| Proven       | Verified by execution or direct artifact evidence             |
| Claimed      | Stated in documentation but not verified                      |
| Contradicted | Documentation and implementation disagree                     |
| Unknown      | Not enough evidence                                           |
| Not started  | No implementation exists                                      |
| Partial      | Some implementation exists, but the contract is not fully met |

## Evidence rules

1. A claim is `Claimed` until it has an execution log, a test result, or a direct file reference.
2. A decision is only authoritative when it is tracked in git and has a decision ID.
3. Findings keep their original IDs. Do not renumber. Mark them `Fixed` with the commit or test evidence.
4. Do not update a finding to `Fixed` because the code looks correct. Update it after a deployment test passes.

## Current one-line status

The design layer is substantial. The implementation is a single untested cloud-init monolith. The new repository structure is mostly empty placeholders. Goals are not yet formally confirmed. Several strategic decisions contradict the implementation. No deployment evidence exists.
