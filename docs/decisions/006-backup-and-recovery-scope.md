---
name: "ADR-006: Backup and Recovery Scope"
description: |
  Decision on whether Restic backup is in v1.0 and which state it covers.
status: draft
version: 1.0
updated: 2026-11-12
---

# ADR-006: Backup and Recovery Scope

## Context

The block volume holds certificates, Authelia data, WireGuard keys, and application data. The VM is disposable. Q4 asks whether Restic backup is in v1.0. Deferring backup risks total state loss.

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
