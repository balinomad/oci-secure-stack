---
name: "ADR-007: OCI Provisioning Method"
description: |
  Decision on whether OCI prerequisites are manual or Terraform-managed.
status: draft
version: 1.1
updated: 2026-11-13
---

# ADR-007: OCI Provisioning Method

## Context

The OCI network, block volume, Vault secrets, and DNS records must exist before the instance boots. Q5 asks whether these prerequisites are manual or Terraform-managed. Manual provisioning creates drift and weakens the reproducible-deployment goal.

## Affected paths

- `docs/guides/getting-started.md`
- `docs/guides/operations.md` section 15
- `docs/process/issue-log.md` F21

## Current text or behavior

The OCI network, block volume, Vault secrets, and DNS records are manual prerequisites. The repository has no Terraform for OCI infrastructure, Vault, IAM, or DNS.

## Contradiction

The reproducible-deployment goal requires infrastructure as code. The prerequisites are manual and can drift.

## Options

1. Keep manual provisioning for v1.0.
2. Use Terraform for the OCI prerequisites in v1.0.
3. Use manual provisioning for v1.0 and Terraform in v1.1.

## Consequences of each option

- Option 1: delivery is fastest. Drift and weak reproducibility remain, and F21 stays open.
- Option 2: the prerequisites become reproducible. Terraform code and state management are added, and v1.0 is delayed.
- Option 3: v1.0 remains manual and a Terraform migration is planned. Temporary drift is accepted, and the v1.0 schedule is preserved.

## Recommendation

Adopt option 3.

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
