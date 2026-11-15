---
name: "ADR-007: OCI Provisioning Method"
description: |
  Decision on whether OCI prerequisites are manual or Terraform-managed.
status: draft
version: 1.2
updated: 2026-11-14
---

# ADR-007: OCI Provisioning Method

## Context

The OCI network, block volume, Vault secrets, and DNS records must exist before the instance boots. Q5 asks whether these prerequisites are manual or Terraform-managed. Manual provisioning creates drift and weakens the reproducible-deployment goal.

## Affected paths

- `docs/guides/getting-started.md`
- `docs/guides/operations.md` section 15
- `docs/process/issue-log.md` F21

## Current text or behavior

The OCI network, block volume, Vault secrets, and DNS records are manual prerequisites for this repository. Terraform for OCI infrastructure is part of v1.0. This repository contains no Terraform. Coverage of Vault, IAM, and DNS is unverified.

## Contradiction

The reproducible-deployment goal requires infrastructure as code. This repository does not implement OCI provisioning as code, so reproducibility is unproven.

## Options

1. Keep manual provisioning for v1.0.
2. Use Terraform for the OCI prerequisites in v1.0.
3. Use manual provisioning for v1.0 and Terraform in v1.1.

## Consequences of each option

- Option 1: delivery is fastest. Drift and weak reproducibility remain, and F21 stays open.
- Option 2: the prerequisites become reproducible. Terraform code and state management are added, and v1.0 is delayed.
- Option 3: v1.0 remains manual and a Terraform migration is planned. Temporary drift is accepted, and the v1.0 schedule is preserved.

## Recommendation

Adopt option 2.

## Decision

1. Terraform for OCI infrastructure is part of v1.0.
2. This repository remains infrastructure-only and contains no Terraform.
3. The Terraform implementation must cover the OCI network, block volume, Vault secrets, IAM, and DNS prerequisites before F21 can be closed.

## Consequences

- OCI prerequisites are managed as code.
- This repository remains infrastructure-only.
- F21 remains open until the Terraform coverage is verified.
- The Terraform state and provider versions require governance.

## References

- `docs/architecture.md`
- `docs/guides/getting-started.md`
- `docs/process/delivery-plan.md`
- `docs/process/issue-log.md`
