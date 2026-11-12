---
name: "ADR-009: Infrastructure Container Runtime"
description: |
  Decision on whether infrastructure containers use Quadlet or plain systemd units.
status: draft
version: 1.0
updated: 2026-11-12
---

# ADR-009: Infrastructure Container Runtime

## Context

Authelia and wg-easy run as plain systemd units with `podman run`. Only application containers use Quadlet. Q6 asks whether infrastructure containers must use Quadlet. Plain units work but conflict with the consistency goal.

## Open question

Are infrastructure containers required to use Quadlet?

Recommended default: yes, for consistency.

Trade-off if reversed: plain systemd units work but contradict the consistency requirement.

## Decision

Not decided.

## Consequences

Not determined until the open question is resolved.

## References

- `docs/architecture.md`
- `docs/process/delivery-plan.md`
- `docs/process/issue-log.md`
