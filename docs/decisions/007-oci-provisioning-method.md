---
name: "ADR-007: OCI Provisioning Method"
description: |
  Decision on whether OCI prerequisites are manual or Terraform-managed.
status: draft
version: 1.0
updated: 2026-11-12
---

# ADR-007: OCI Provisioning Method

## Context

The OCI network, block volume, Vault secrets, and DNS records must exist before the instance boots. Q5 asks whether these prerequisites are manual or Terraform-managed. Manual provisioning creates drift and weakens the reproducible-deployment goal.

## Open question

Are OCI prerequisites manual or Terraform-managed?

Recommended default: manual for v1, Terraform as v1.1.

Trade-off if reversed: manual creates drift and weakens the reproducible-deployment goal.

## Decision

Not decided.

## Consequences

Not determined until the open question is resolved.

## References

- `docs/architecture.md`
- `docs/guides/getting-started.md`
- `docs/process/delivery-plan.md`
- `docs/process/issue-log.md`
