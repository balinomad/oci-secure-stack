---
name: "ADR-010: Local Monitoring UI and Historical Retention"
description: |
  Decision to provide a loopback-only Grafana UI over PCP metrics, with an optional Valkey history profile.
status: draft
version: 1.0
updated: 2026-11-14
---

# ADR-010: Local Monitoring UI and Historical Retention

## Context

ADR-003 selects PCP as the metrics data plane and rejects a full Prometheus server. PCP provides `pmcd`, `pmlogger`, and a Prometheus-compatible `pmproxy` endpoint, but it provides no general-purpose dashboard. Without a dashboard, an operator must use command-line tools or build ad hoc queries.

The stack needs one local view of host and container health without a paid service and without a full Prometheus server. The view must remain available when no external monitoring server exists. The design must also accept an external Prometheus server later without changing the data plane.

PCP can store history in Valkey or Redis through `pmproxy`. That storage adds memory and disk requirements. The live dashboard must work on a 4 GB instance. Historical retention requires more capacity and is optional.

## Affected paths

- `infra/cloud-init/cloud-config.example.yaml` sections `PACKAGES`, `runcmd`, and `Start Services`
- `configs/manifest.yaml`
- `configs/pcp/`
- `configs/grafana/`
- `configs/valkey/`
- `configs/systemd/pcp-openmetrics.conf`
- `configs/systemd/grafana-server.service.d/`
- `configs/systemd/valkey.service.d/`
- `configs/traefik/traefik.yml`
- `configs/traefik/dynamic/infra.yml`
- `configs/authelia/configuration.yml`
- `scripts/host/deploy/07-monitoring.sh`
- `scripts/host/verify-stack.sh`
- `docs/reference/infrastructure.md` section 8
- `docs/guides/getting-started.md` sections 1, 3, 4, 6, 8, and 10
- `docs/guides/operations.md` sections 1, 2, 3, 4, 9, and 14
- `docs/guides/adding-apps.md` sections 11 and 12
- `docs/architecture.md` sections `System architecture` and `Component roles`
- `docs/decisions/001-exposure-model.md`
- `docs/decisions/003-metrics-architecture.md`
- `docs/decisions/006-backup-and-recovery-scope.md`
- `docs/process/issue-log.md` F8
- `docs/process/project-status.md`

## Current text or behavior

The static configuration installs `pcp`, `pcp-zeroconf`, `pcp-pmda-podman`, and `pcp-pmda-openmetrics`. It starts `pmcd`, `pmlogger`, `pmproxy`, and `pmie`. The OpenMetrics PMDA reads the Traefik metrics endpoint on `127.0.0.1:8082`. The live profile installs Grafana, and the history profile adds Valkey.

## Contradiction

The design requires one local monitoring view and stable metric names for a future external Prometheus server. The static configuration implements this design. No deployment evidence exists.

## Options

1. Keep PCP command-line tools only. Do not add a dashboard or history store.
2. Add Grafana OSS with the `grafana-pcp` plugin and the PCP Vector datasource. Keep PCP as the data plane. Do not add a history store.
3. Add Grafana OSS with the `grafana-pcp` plugin and add Valkey for PCP `pmseries` history.

## Consequences of each option

- Option 1: resource use stays lowest. The operator has no single view, and dashboard work remains manual. The monitoring goal is not met.
- Option 2: the operator gets one local view with live metrics. Resource use fits a 4 GB instance. History is limited to PCP archives, and ad hoc long-range queries require PCP tools.
- Option 3: the operator gets live and historical views. Valkey adds memory and disk use, a state directory, and a backup concern. A 6 GB instance is the minimum planning target.

## Recommendation

Adopt option 2 as the default live profile. Keep option 3 as an explicit historical profile for deployments that meet its capacity requirements. Do not deploy a full Prometheus server in either profile.

## Decision

1. The default monitoring profile is `live`. It installs Grafana OSS with `grafana-pcp` and uses the PCP Vector datasource against `pmproxy`.
2. The optional `history` profile adds Valkey for PCP `pmseries` history. It is not enabled by default.
3. The live profile minimum is 4 GB total RAM, 2 vCPU, and 2 GB free disk. The history profile minimum is 6 GB total RAM, 2 vCPU, and 5 GB free disk. These are architecture-neutral minimums, not a statement about the current OCI shape.
4. The PCP data plane consists of `pmcd`, `pmlogger`, `pmproxy`, `pcp-pmda-podman`, `pcp-pmda-openmetrics`, and `pmie`. `pmproxy` is the only Prometheus-compatible endpoint and binds to `127.0.0.1:44322`.
5. Grafana binds to `127.0.0.1:3000`. Valkey binds to `127.0.0.1:6379`. No Traefik route exists for Grafana, Valkey, `pmproxy`, or raw metrics. Access is through an SSH tunnel.
6. Grafana state is stored under `/data/monitoring/grafana`. Valkey state is stored under `/data/monitoring/valkey`.
7. The Grafana admin password comes from OCI Vault as `grafana-admin-password` with the deployment binding `GRAFANA_SECRET_OCID`. The password is never written to a tracked file.
8. An external Prometheus server is not deployed now. The design keeps the single `pmproxy` endpoint and stable PCP metric names so an external server can scrape it later without a data-plane change.
9. The exact package, port, and capacity requirements are canonical in `docs/reference/infrastructure.md` section 8.

## Consequences

- `pmproxy` and the two PMDAs are mandatory in both profiles. Grafana and Valkey are profile-dependent.
- The live profile fits the current 2 OCPU and 4 GB instance. The history profile requires a 6 GB instance.
- Grafana and Valkey are not exposed through Traefik. Operators use SSH local forwarding.
- Monitoring state survives VM replacement only when `/data/monitoring` is present on the block volume.
- Valkey history is additional state. A backup or restore procedure must cover it or explicitly exclude it.
- A future external Prometheus server can scrape `127.0.0.1:44322` through a secure tunnel. It does not require a public metrics route.
- The decision remains unverified until a deployment records PCP export, Grafana health, and the selected profile.

## References

- `docs/decisions/003-metrics-architecture.md`
- `docs/decisions/001-exposure-model.md`
- `docs/reference/infrastructure.md` section 8
- `docs/guides/operations.md`
- `docs/process/issue-log.md` F8
