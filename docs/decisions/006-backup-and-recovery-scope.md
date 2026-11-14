---
name: "ADR-006: Backup and Recovery Scope"
description: |
  Decision on whether Restic backup is in v1.0 and which state it covers.
status: draft
version: 1.2
updated: 2026-11-14
---

# ADR-006: Backup and Recovery Scope

## Context

The block volume holds certificates, Authelia data, WireGuard keys, application data, and the optional monitoring history. The VM is disposable. Q4 asks whether Restic backup is in v1.0. Deferring backup risks total state loss.

## Affected paths

- `docs/architecture.md`
- `docs/guides/operations.md` section 11
- `docs/decisions/010-monitoring-presentation.md`
- `docs/process/issue-log.md` F22

## Current text or behavior

The architecture and operations guide describe Restic backup. The implementation has no Restic, timer, bucket, or backup secret. The optional historical monitoring profile adds `/data/monitoring/valkey` as state that a backup must cover or explicitly exclude.

## Contradiction

The block volume holds irreplaceable state. v1.0 has no implemented backup.

## Options

1. Defer Restic to v1.1.
2. Include Restic backup in v1.0 for the block volume and the secret material it needs.
3. Use an alternative backup mechanism, such as OCI block volume backups.

## Consequences of each option

- Option 1: no backup exists. Total state loss is possible after volume failure or operator error, and F22 remains open.
- Option 2: state is recoverable. The stack adds a bucket, a timer, and a backup secret, and restore testing is required.
- Option 3: provider-level volume backups are available. They may not cover application-consistent state or secret recovery, and they use a different operational model.

## Recommendation

Adopt option 2.

## Open question

Is Restic backup in v1.0?

Recommended default: yes, if the block volume holds irreplaceable data.

Trade-off if reversed: deferring backup risks total state loss.

## Decision

Not decided.

## Consequences

Not determined until the open question is resolved.

## References

- `docs/architecture.md`
- `docs/process/delivery-plan.md`
- `docs/process/issue-log.md`
