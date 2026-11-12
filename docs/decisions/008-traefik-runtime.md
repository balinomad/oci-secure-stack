---
name: "ADR-008: Traefik Runtime"
description: |
  Decision to run Traefik as a native binary under a hardened systemd unit instead of a container.
status: draft
version: 1.0
updated: 2026-11-12
---

# ADR-008: Traefik Runtime

## Context

The edge router binds privileged ports 80 and 443. A rootless container would require port forwarding or elevated capabilities. A native binary under systemd can bind the ports directly and use systemd hardening controls.

## Decision

1. Run Traefik as a native binary.
2. Manage it with a hardened systemd unit.
3. Do not run Traefik as a Podman container.
4. Bind public traffic on ports 80 and 443.
5. Bind the dashboard and metrics endpoints to loopback as defined in ADR-001.

## Consequences

- Traefik upgrades are managed through the system package or a pinned binary release.
- The systemd unit must carry the sandboxing and filesystem restrictions.
- SELinux policy must permit binding ports 80 and 443.
- Container-based deployment tooling does not apply to Traefik.

## References

- `docs/process/component-research.md`
- `docs/decisions/001-exposure-model.md`
