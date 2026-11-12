---
name: "ADR-001: Management Plane Exposure Model"
description: |
  Decision to keep the Traefik dashboard and metrics endpoints on loopback, and to require Authelia plus PAM for Cockpit.
status: draft
version: 1.0
updated: 2026-11-12
---

# ADR-001: Management Plane Exposure Model

## Context

The Traefik dashboard, Traefik API, and raw metrics endpoints expose sensitive operational data. Findings F6, F8, and F9 record conflicting or unsafe exposure in the current implementation. Cockpit cannot securely trust proxy authentication headers and requires its own PAM login.

## Decision

1. Bind the Traefik dashboard and API to `127.0.0.1:8080`.
2. Bind the Traefik metrics endpoint to `127.0.0.1:8082`.
3. Do not create Traefik routes for the dashboard, API, or raw metrics.
4. Access the dashboard through SSH local port forwarding only.
5. Bind Cockpit to `127.0.0.1:9090` and route it through Traefik only behind Authelia with VPN and TOTP.
6. Cockpit performs its own PAM authentication. Do not trust proxy authentication headers for Cockpit sessions.
7. Any future exposure of the management plane requires a new ADR.

## Consequences

- Operators need an SSH tunnel to reach the dashboard and metrics.
- Cockpit requires two authentication steps: Authelia and PAM.
- F6 and F9 are addressed by removing direct exposure. Implementation and deployment verification remain.
- F8 is addressed by removing the metrics self-proxy route. Implementation and deployment verification remain.
- The metrics backend remains loopback-only, as defined in ADR-003.

## References

- `docs/process/component-research.md`
- `docs/process/findings-register.md` F6, F8, F9
