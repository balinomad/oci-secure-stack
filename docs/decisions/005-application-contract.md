---
name: "ADR-005: Application Container Contract"
description: |
  Decision to run application containers rootless under dedicated users, with restricted volumes, minimal capabilities, and non-world-readable secrets.
status: draft
version: 1.0
updated: 2026-11-12
---

# ADR-005: Application Container Contract

## Context

The current deployment path runs services as `opc`, writes environment values into world-readable manifests, and accepts unrestricted volume sources. Findings F11, F12, and F13 record these defects.

## Decision

1. Run application containers rootless under dedicated non-login users.
2. Manage application containers with Quadlet.
3. Restrict volume sources to paths under `/data/`.
4. Do not write secret values into world-readable manifest files.
5. Use Podman secrets or root-only environment files for secret values.
6. Grant only the capabilities the application requires. Remove unnecessary capabilities such as `SYS_MODULE`.
7. Record the image, digest, volumes, ports, and secret references in the deployment manifest.

## Consequences

- `deploy-service.sh` must validate volume sources and secret handling.
- F11, F12, and F13 are addressed by the new contract. Implementation and deployment verification remain.
- Application onboarding requires a dedicated user and a Quadlet unit.
- Secret rotation must update the secret store, not rewrite a manifest.

## References

- `docs/process/component-research.md`
- `docs/process/findings-register.md` F11, F12, F13
