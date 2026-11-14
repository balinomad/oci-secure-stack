---
name: "ADR-005: Application Container Contract"
description: |
  Decision to run application containers rootless under dedicated users, with restricted volumes, minimal capabilities, and non-world-readable secrets.
status: draft
version: 1.2
updated: 2026-11-14
---

# ADR-005: Application Container Contract

## Context

The current deployment path runs services as `opc`, writes environment values into world-readable manifests, and accepts unrestricted volume sources. Findings F11 and F13 record the manifest and volume defects.

## Affected paths

- `infra/host/deploy-service.sh:19-20,108-123,125-130,187-206,232-239`
- `docs/process/issue-log.md` F11, F13, F29

## Current text or behavior

The deployment script runs services as `opc` or root. It writes `--env` values into `Environment=` in a Quadlet unit and into a world-readable manifest. It does not validate volume sources.

## Contradiction

The design requires rootless application containers under dedicated users, restricted volumes, minimal capabilities, and non-world-readable secrets. The script does not enforce that contract.

## Options

1. Keep the current rootful deployment with environment values in manifests.
2. Run applications rootless under dedicated users, use Quadlet, restrict volumes to `/data/`, and use Podman secrets or root-only environment files.
3. Run applications rootless but keep the current manifest format and no volume validation.

## Consequences of each option

- Option 1: secrets may be world-readable, volumes remain unrestricted, and F11, F13, and F29 remain open.
- Option 2: each application needs a dedicated user and a Quadlet unit. Volume validation and secret rotation are required. F11, F13, and F29 are addressed.
- Option 3: the privilege boundary improves, but the manifest and volume defects remain.

## Recommendation

Adopt option 2.

## Decision

1. Run application containers rootless under dedicated non-login users.
2. Manage application containers with Quadlet.
3. Restrict volume sources to paths under `/data/`.
4. Do not write secret values into world-readable manifest files.
5. Use Podman secrets or root-only environment files for secret values.
6. Grant only the capabilities the application requires. Remove unnecessary capabilities such as `SYS_MODULE`.
7. Record the image, digest, volumes, ports, and secret references in the deployment manifest.

## Consequences

- `infra/host/deploy-service.sh` must validate volume sources and secret handling.
- F11 and F13 are addressed by the new contract. Implementation and deployment verification remain.
- Application onboarding requires a dedicated user and a Quadlet unit.
- Secret rotation must update the secret store, not rewrite a manifest.

## References

- `tmp/unverified/component-research.md`
- `docs/process/issue-log.md` F11, F13
