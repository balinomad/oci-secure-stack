---
name: "ADR-008: Traefik Runtime"
description: |
  Decision to run Traefik as a native binary under a hardened systemd unit instead of a container.
status: draft
version: 1.1
updated: 2026-11-13
---

# ADR-008: Traefik Runtime

## Context

The edge router binds privileged ports 80 and 443. A rootless container would require port forwarding or elevated capabilities. A native binary under systemd can bind the ports directly and use systemd hardening controls.

## Affected paths

- `infra/cloud-init/cloud-config.example.yaml:95-130,809`
- `docs/reference/traefik.md:12-80`

## Current text or behavior

Traefik runs as a native binary under a systemd unit and binds ports 80 and 443. The dashboard and metrics endpoints are intended to bind to loopback under ADR-001.

## Contradiction

The edge router needs privileged ports. A rootless container would need port forwarding or elevated capabilities, which conflicts with the minimal-privilege goal.

## Options

1. Run Traefik as a native binary under a hardened systemd unit.
2. Run Traefik as a rootless container with port forwarding.
3. Run Traefik as a rootful container with elevated capabilities.

## Consequences of each option

- Option 1: Traefik binds directly to ports 80 and 443. The unit needs systemd sandboxing and an SELinux port policy. Upgrades use the system package or a pinned binary release.
- Option 2: the container is rootless. A port forwarder or reverse proxy is required, and the deployment has more moving parts.
- Option 3: port binding is simple. The container retains rootful privileges, and the blast radius is larger.

## Recommendation

Adopt option 1.

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

- `tmp/unverified/component-research.md`
- `docs/decisions/001-exposure-model.md`
