---
name: "ADR-003: Metrics Architecture"
description: |
  Decision to use PCP-native metrics export instead of a full Prometheus server, with all endpoints bound to loopback.
status: draft
version: 1.2
updated: 2026-11-14
---

# ADR-003: Metrics Architecture

## Context

A full Prometheus server, TSDB, and Alertmanager are redundant for an instance that fits within the Oracle Cloud Free Tier Always Free services limits. PCP is available on Oracle Linux 9 and can expose a Prometheus-compatible endpoint. Finding F8 requires PCP metrics export without a public route.

## Affected paths

- `infra/cloud-init/cloud-config.example.yaml` sections `PACKAGES` and `runcmd`
- `configs/pcp/`
- `docs/reference/traefik.md` metrics section
- `docs/reference/infrastructure.md` sections 6 and 8
- `docs/process/issue-log.md` F8

## Current text or behavior

The static configuration exposes PCP metrics through `pmproxy`, the Podman PMDA, and the OpenMetrics PMDA. No public metrics route exists. No deployment evidence exists.

## Contradiction

The design requires PCP host metrics on a loopback endpoint and no public `metrics.` route. The static configuration matches the design. No deployment evidence exists.

## Options

1. Keep the Traefik self-metrics route and the `metrics.` hostname.
2. Expose PCP metrics on a loopback endpoint, keep Traefik internal metrics on loopback, and remove the public route.
3. Deploy a full Prometheus server, TSDB, and Alertmanager.

## Consequences of each option

- Option 1: the public metrics route remains. F8 remains open, and host metrics are unavailable.
- Option 2: there is no long-term TSDB and no built-in alerting. Operators use PCP or an SSH tunnel, and the metrics route is removed.
- Option 3: full metrics and alerting are available. Resource use and operational overhead increase, and the capacity is unnecessary for the Free Tier instance.

## Recommendation

Adopt option 2.

## Decision

1. Use PCP (`pmcd`, `pmlogger`) for host metrics.
2. Expose a Prometheus-compatible endpoint through PCP, bound to `127.0.0.1`.
3. Do not deploy a full Prometheus server or Alertmanager for v1.0.
4. Keep Traefik internal metrics bound to `127.0.0.1:8082`.
5. Do not create a `metrics.${DOMAIN}` route. Exposure is governed by ADR-001.
6. ADR-010 defines the local Grafana presentation layer and the optional Valkey history profile. It does not replace this data-plane decision.
7. Keep `pmproxy` as the single Prometheus-compatible endpoint. An external Prometheus server can scrape it later without changing the PCP data plane.

## Consequences

- The stack has no long-term Prometheus TSDB and no built-in alerting.
- Operators use PCP tooling, Grafana through an SSH tunnel, or a future external Prometheus server.
- The static configuration has no metrics route.
- The local Grafana presentation and optional Valkey retention are defined in ADR-010.
- This decision supersedes the metrics routing proposal in Section 2 of `tmp/unverified/component-research.md`.

## References

- `tmp/unverified/component-research.md`
- `docs/decisions/010-monitoring-presentation.md`
- `docs/process/issue-log.md` F8
