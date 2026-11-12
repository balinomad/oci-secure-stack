---
name: "ADR-002: Authelia Runtime and File Ownership"
description: |
  Decision to run Authelia as a rootless Podman container under a dedicated user with persistent state on the data volume.
status: draft
version: 1.0
updated: 2026-11-12
---

# ADR-002: Authelia Runtime and File Ownership

## Context

Authelia holds session keys, TOTP secrets, and the user database. Running it as root expands the blast radius. Finding F1 records a likely ownership mismatch between root-owned files and the non-root user in the official image.

## Decision

1. Run Authelia as a rootless Podman container.
2. Run it under a dedicated non-login user, not `opc` and not `root`.
3. Enable systemd lingering for that user so the service starts after boot without an active session.
4. Store configuration, database, and encryption keys under `/data/authelia/`.
5. Set ownership and permissions to match the container UID.
6. Persist JWT, session, and storage encryption keys across VM replacement.
7. Generate missing secrets during first boot, then keep them on the data volume.
8. Do not use rootful Authelia as the default.

## Consequences

- `cloud-init` must create the user, enable lingering, and set ownership before the first start.
- F1 must be verified with a deployment test.
- Rootless networking must bind Authelia to `127.0.0.1:9091`.
- Secret bootstrap must be idempotent.

## References

- `docs/process/component-research.md`
- `docs/process/findings-register.md` F1
