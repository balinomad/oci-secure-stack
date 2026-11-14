---
name: "ADR-009: Infrastructure Container Runtime"
description: |
  Decision on whether infrastructure containers use Quadlet or plain systemd units.
status: draft
version: 1.1
updated: 2026-11-13
---

# ADR-009: Infrastructure Container Runtime

## Context

The template defined Authelia and wg-easy as plain systemd units with `podman run`. Application containers use Quadlet through `scripts/host/deploy-service.sh`. The repository contains no deployment evidence for either infrastructure unit. The open question was whether infrastructure containers must use Quadlet. The runtime decision also sets the privilege boundary for each container.

## Affected paths

- `infra/cloud-init/cloud-config.example.yaml:426-485`
- `scripts/host/verify-stack.sh:155-177`
- `docs/process/issue-log.md` F10, F12, F25

## Current text or behavior

The template defined Authelia and wg-easy as plain systemd units with `podman run`. The static conversion to Quadlet is applied. Authelia is rootless under ADR-002. wg-easy is rootful in a user namespace with `NET_ADMIN` and `NET_RAW`.

## Contradiction

The design requires Quadlet for both infrastructure containers and a defined privilege boundary. The repository has no deployment evidence for either unit.

## Options

1. Keep plain systemd units with `podman run`.
2. Use Quadlet for both containers. Run Authelia rootless and wg-easy rootful in a user namespace with minimal capabilities.
3. Use Quadlet for both containers and run wg-easy rootless with port forwarding.

## Consequences of each option

- Option 1: Quadlet generation and dependency handling are absent. F10 and F25 remain open.
- Option 2: both containers use consistent Quadlet management. wg-easy keeps the minimum privileged capabilities, and deployment tests are required.
- Option 3: wg-easy isolation is stronger. Port forwarding or elevated capabilities are required for WireGuard, and the deployment is more complex.

## Recommendation

Adopt option 2.

## Decision

1. Use Quadlet for both infrastructure containers.
2. Run Authelia as a rootless user unit under ADR-002.
3. Run wg-easy as a rootful system unit inside a user namespace. Map container UID and GID 0 to host IDs `300000-365535`.
4. Add only the `NET_ADMIN` and `NET_RAW` capabilities to wg-easy. Pass `/dev/net/tun`. Do not add `SYS_MODULE`.
5. Preload the `wireguard` kernel module. If the module is unavailable, wg-quick falls back to `wireguard-go`.
6. Keep Traefik as a native binary under ADR-008.
7. Treat wg-easy as the only privileged infrastructure container.

## Consequences

- Authelia installs under `/etc/containers/systemd/users/<authelia-uid>/authelia.container`. wg-easy installs under `/etc/containers/systemd/wg-easy.container`.
- `/data/containers/wg-easy` must be owned by host UID and GID `300000`.
- The wg-easy mapping must not overlap the Authelia subordinate range.
- `NET_ADMIN` is required for interface and route changes. `NET_RAW` supports ICMP handling.
- `SYS_MODULE` is not namespaced and is unnecessary when the module is preloaded or the userspace fallback is used.
- Deployment tests must prove Quadlet generation for both units, a rootless Authelia start, wg-easy port publication and a handshake inside the user namespace, no AVC denials, and persistence after reboot.
- The template implements this decision. The decision remains unverified until those tests pass.

## References

- `docs/decisions/002-authelia-runtime.md`
- `docs/decisions/008-traefik-runtime.md`
- `docs/process/issue-log.md` F10, F12
- `docs/architecture.md`
