---
name: "ADR-001: Management Plane Exposure Model"
description: |
  Decision to keep the Traefik dashboard, metrics endpoints, Grafana, and Valkey on loopback, and to require Authelia plus PAM for Cockpit.
status: draft
version: 1.2
updated: 2026-11-14
---

# ADR-001: Management Plane Exposure Model

## Context

The Traefik dashboard, Traefik API, raw metrics endpoints, Grafana, and Valkey expose sensitive operational data. Findings F6, F8, and F9 define the exposure defects this decision addresses. Cockpit cannot securely trust proxy authentication headers and requires its own PAM login.

## Affected paths

- `infra/cloud-init/cloud-config.example.yaml` sections `PACKAGES`, `runcmd`, and `Start Services`
- `configs/grafana/grafana.ini`
- `configs/valkey/valkey.conf`
- `docs/reference/infrastructure.md` sections 2, 4, and 6
- `docs/process/issue-log.md` F6, F8, F9

## Current text or behavior

The static configuration keeps the Traefik dashboard and metrics endpoints on loopback. Cockpit binds to loopback. No deployment evidence exists.

## Contradiction

The design requires loopback-only management endpoints and Authelia plus PAM for Cockpit. The static configuration matches the design. No deployment evidence exists.

## Options

1. Keep public routes and direct Cockpit access.
2. Bind the dashboard, API, and metrics to loopback. Bind Cockpit to loopback and route it through Traefik behind Authelia and PAM.
3. Bind all management endpoints to loopback and require SSH tunnels, with no Traefik route for Cockpit.

## Consequences of each option

- Option 1: public exposure persists. F6 and F9 remain open.
- Option 2: operators need an SSH tunnel for the dashboard and metrics. Cockpit requires Authelia and PAM. F6, F8, and F9 are addressed.
- Option 3: isolation is strongest. Cockpit also requires an SSH tunnel. The Traefik and Authelia route for Cockpit is lost, and operator friction increases.

## Recommendation

Adopt option 2.

## Decision

1. Bind the Traefik dashboard and API to `127.0.0.1:8080`.
2. Bind the Traefik metrics endpoint to `127.0.0.1:8082`.
3. Do not create Traefik routes for the dashboard, API, or raw metrics.
4. Access the dashboard through SSH local port forwarding only.
5. Bind Cockpit to `127.0.0.1:9090`. Route Cockpit through Traefik only behind Authelia with VPN and TOTP.
6. Cockpit performs its own PAM authentication. Do not trust proxy authentication headers for Cockpit sessions.
7. Bind Grafana to `127.0.0.1:3000` and Valkey to `127.0.0.1:6379`. Do not create Traefik routes for Grafana, Valkey, or `pmproxy`. Access is through an SSH tunnel.
8. Any future exposure of the management plane requires a new ADR.

## Consequences

- Operators need an SSH tunnel to reach the dashboard and metrics.
- Cockpit requires two authentication steps: Authelia and PAM.
- F6 and F9 require deployment verification of loopback-only exposure and Cockpit PAM login.
- F8 requires deployment verification of PCP export and the metrics restriction.
- The metrics backend remains loopback-only, as defined in ADR-003.
- Grafana and Valkey need an SSH tunnel. They do not add a public or VPN-routed web surface.
- The monitoring UI and history profile are defined in ADR-010.

## References

- `tmp/unverified/component-research.md`
- `docs/process/issue-log.md` F6, F8, F9
