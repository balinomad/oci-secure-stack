---
name: "ADR-011: Alert Delivery"
description: |
  Decision to deliver local alerts through PCP pmie, systemd failure hooks, an HTTPS webhook, and an external heartbeat.
status: draft
version: 1.2
updated: 2026-11-14
---

# ADR-011: Alert Delivery

## Context

The stack has one local monitoring view over PCP, but no alert delivery path. An operator must inspect Grafana, `pmie`, systemd state, and the journal manually. A stopped service, a full filesystem, low memory, an expiring certificate, or a lost instance can remain unnoticed.

A full Prometheus server and Alertmanager are excluded by ADR-003. The Free Tier instance cannot justify their resource use. The stack still needs a small path that reaches a human when the instance is degraded or unavailable. The path must not add an inbound listener or a public route.

PCP is already installed and provides `pmie` for local threshold evaluation. systemd provides failure hooks and timers. An external heartbeat is the only control that detects total instance loss. OCI blocks outbound TCP 25 by default, so SMTP is not a reliable channel.

## Affected paths

- `infra/runtime/alerting/alerting.sh`
- `infra/configs/alerting/env.example`
- `infra/configs/alerting/services.list`
- `infra/configs/pcp/pmie/stack-alerts.pmie`
- `infra/configs/systemd/pcp-alert-pmie.service`
- `infra/configs/systemd/pcp-alert-notify@.service`
- `infra/configs/systemd/pcp-service-check.service`
- `infra/configs/systemd/pcp-service-check.timer`
- `infra/configs/systemd/pcp-cert-check.service`
- `infra/configs/systemd/pcp-cert-check.timer`
- `infra/configs/systemd/pcp-heartbeat.service`
- `infra/configs/systemd/pcp-heartbeat.timer`
- `infra/configs/systemd/pcp-alerting.conf`
- `infra/configs/systemd/traefik.service.d/onfailure.conf`
- `infra/configs/systemd/wg-easy.service.d/onfailure.conf`
- `infra/configs/systemd/pmcd.service.d/onfailure.conf`
- `infra/configs/systemd/pmlogger.service.d/onfailure.conf`
- `infra/configs/systemd/pmproxy.service.d/onfailure.conf`
- `infra/configs/systemd/grafana-server.service.d/onfailure.conf`
- `infra/configs/systemd/valkey.service.d/onfailure.conf`
- `infra/manifest.yaml`
- `infra/config-index.md`
- `infra/configs/oci-vault/secret-inventory.yaml`
- `infra/cloud-init/cloud-config.template.yaml` sections `USERS & GROUPS`, `PACKAGES`, `runcmd`, and `Start Services`
- `infra/host/08-alerting.sh`
- `infra/host/verify-stack.sh`
- `.env.example`
- `docs/reference/infrastructure.md` sections 1, 4, 5, 6, 7, 8, and 9
- `docs/guides/getting-started.md` sections 1, 3, 4, 6, 8, and 10
- `docs/guides/operations.md` sections 1, 2, 4.7, 4.7.1, 4.7.2, 9, and 14
- `README.md`
- `docs/architecture.md` sections `Component roles`, `Security model`, and `Decision index`
- `docs/decisions/003-metrics-architecture.md`
- `docs/decisions/010-monitoring-presentation.md`
- `docs/decisions/decision-index.md`
- `docs/process/issue-log.md` F30
- `docs/process/project-status.md`
- `docs/process/acceptance-criteria.md`
- `docs/process/delivery-plan.md`
- `docs/process/process-index.md`

## Current text or behavior

The PCP data plane runs `pmcd`, `pmlogger`, `pmproxy`, and `pmie`. No `pmie` rules invoke an external notifier. No systemd `OnFailure=` hook exists. No certificate expiry check exists. No external heartbeat exists. Before this decision, `docs/guides/operations.md` section 4.7.1 stated that automated alert delivery was not configured.

The implementation adds a dedicated `alerting` system user, a notifier, a dedicated `pmie` instance, service and certificate timers, an external heartbeat timer, and failure hooks for the core system units. The runtime webhook and heartbeat URLs come from OCI Vault and are stored in `/data/monitoring/alerting/env`.

## Contradiction

The architecture requires evidence of operational health and the issue log requires a path for service failure. The static configuration now provides that path, but no deployment has delivered an alert or proven the external heartbeat. The decision remains unverified until a test alert and a stopped-instance test are recorded.

## Options

1. Keep manual checks only.
2. Use PCP `pmie` rules, systemd `OnFailure=` hooks, one HTTPS webhook, and an external heartbeat.
3. Use OCI Monitoring and Notifications.
4. Use Grafana alerting.
5. Deploy Prometheus and Alertmanager.

## Consequences of each option

- Option 1: no new component. Failures remain invisible until an operator checks manually. The operational goal is not met.
- Option 2: small resource use and no inbound listener. Alerts depend on an external webhook and an external heartbeat provider. The stack must manage two new Vault secrets and a dedicated service user.
- Option 3: managed delivery and no local agent. It adds OCI metrics ingestion, a paid or limited service boundary, and a second monitoring model beside PCP. It does not reuse the existing `pmie` rules.
- Option 4: no new server. Grafana alerting adds provisioning, contact points, and state to a UI that is optional in the `none` profile. It is unavailable when Grafana is not installed.
- Option 5: the most capable and the most expensive. It contradicts ADR-003 and exceeds the instance capacity target.

## Recommendation

Adopt option 2. Use the existing PCP data plane for local threshold evaluation and systemd for service failure detection. Send one HTTPS webhook and one external heartbeat. Do not add Prometheus, Alertmanager, OCI Monitoring, or Grafana alerting.

## Decision

1. `pmie` evaluates filesystem use above 85 percent, one-minute load above 4, and available memory below 512 MB. The rules are in `/etc/pcp/pmie/stack-alerts.pmie`.
2. `pcp-service-check.timer` checks the core systemd units, the Traefik loopback ping endpoint, and the Authelia loopback health endpoint every two minutes. It does not query another user's systemd manager and does not require root.
3. `pcp-cert-check.timer` checks the earliest certificate in `/data/traefik/letsencrypt/acme.json` daily and alerts below 14 days. It runs as a hardened root one-shot because `acme.json` contains private key material.
4. Systemd `OnFailure=` hooks cover `traefik`, `wg-easy`, `pmcd`, `pmlogger`, `pmproxy`, `grafana-server`, and `valkey`. The notifier is `pcp-alert-notify@.service`.
5. `pcp-heartbeat.timer` sends an external heartbeat every five minutes. The external provider alerts when the heartbeat stops.
6. Alert delivery uses one HTTPS webhook. SMTP is not used because OCI blocks outbound TCP 25 by default.
7. The `alerting` system user owns the notifier, `pmie` alert instance, service checks, and heartbeat. It has no login shell and a service-owned state directory.
8. The webhook and heartbeat URLs come from OCI Vault as `alert-webhook-url` and `alert-heartbeat-url`. They are stored in `/data/monitoring/alerting/env`, mode `0600`, owner `alerting:alerting`.
9. Alerts use a JSON payload with `source`, `message`, `host`, and `time`. The notifier deduplicates transitions and applies a 30-minute cooldown to repeated `pmie` conditions.
10. No inbound port or Traefik route is added. The only network flow is outbound HTTPS.
11. The external heartbeat provider and the webhook receiver are deployment prerequisites. The stack does not include a receiver.
12. The exact thresholds, units, timers, and secret names are canonical in `docs/reference/infrastructure.md` section 9.

## Consequences

- Alert delivery depends on an external webhook receiver and an external heartbeat provider.
- The webhook URL is a secret. A leaked URL permits alert injection. Rotate it through OCI Vault.
- The certificate check is the only alerting component that runs as root. It is a one-shot service with a reduced capability set, a read-only `/data` mount, and write access only to deduplication state.
- The rootless Authelia unit is checked through its loopback health endpoint, not through `systemctl --user`. This avoids a root dependency and a cross-user systemd query.
- Grafana and Valkey failure hooks apply only when those units are installed. The service timer does not check optional units.
- The 30-minute cooldown can delay a repeated alert for a persistent condition. The first transition is immediate.
- The decision remains unverified until a webhook delivery, a service failure, and a stopped-instance heartbeat test are recorded in the acceptance criteria.
- Alerting state is stored under `/var/lib/stack-alerting` and is not part of the block volume backup. It contains deduplication status and timestamps only.

## References

- `docs/decisions/003-metrics-architecture.md`
- `docs/decisions/010-monitoring-presentation.md`
- `docs/reference/infrastructure.md` section 9
- `docs/guides/operations.md` sections 4.7 and 9
- `docs/process/issue-log.md` F30
- `docs/process/acceptance-criteria.md` S13, S14, X13, and X14
