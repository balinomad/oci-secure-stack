---
name: "Infrastructure Reference"
description: |
  Exact template variables, OCI network rules, DNS records, Vault secrets, persistent storage layout, and reserved ports for the stack.
status: draft
version: 1.3
updated: 2026-11-14
---

# Infrastructure Reference

This page documents the OCI infrastructure and host baseline for the stack. See `docs/process/project-status.md` for verification status.

## 1. Template variables

`infra/cloud-init/cloud-config.example.yaml` uses `${VARIABLE}` syntax for site-specific values. All other `${...}` references inside `runcmd` blocks are shell variables and must remain unsubstituted.

| Variable              | Description                                             | Example                       |
| --------------------- | ------------------------------------------------------- | ----------------------------- |
| `${DOMAIN}`           | Base domain for all subdomains                          | `example.com`                 |
| `${ACME_EMAIL}`       | Email for Let's Encrypt expiry notices                  | `ops@example.com`             |
| `${ADMIN_EMAIL}`      | Authelia admin user email                               | `admin@example.com`           |
| `${CF_SECRET_OCID}`   | OCID of the Cloudflare token secret in OCI Vault        | `ocid1.vaultsecret.oc1..xxxx` |
| `${AUTH_SECRET_OCID}` | OCID of the Authelia admin password secret in OCI Vault | `ocid1.vaultsecret.oc1..yyyy` |
| `${WG_SECRET_OCID}`   | OCID of the wg-easy admin password secret in OCI Vault  | `ocid1.vaultsecret.oc1..zzzz` |
| `${GRAFANA_SECRET_OCID}` | OCID of the Grafana admin password secret in OCI Vault | `ocid1.vaultsecret.oc1..gggg` |
| `${ALERT_WEBHOOK_SECRET_OCID}` | OCID of the alert webhook secret in OCI Vault | `ocid1.vaultsecret.oc1..aaaa` |
| `${ALERT_HEARTBEAT_SECRET_OCID}` | OCID of the alert heartbeat secret in OCI Vault | `ocid1.vaultsecret.oc1..bbbb` |
| `${MONITORING_PROFILE}` | Monitoring profile: `live`, `history`, or `none`        | `live`                        |

`${GRAFANA_SECRET_OCID}` is required when `${MONITORING_PROFILE}` is `live` or `history`. The two alert secret OCIDs are required in every profile.

Derived hostnames:

- `auth.${DOMAIN}`
- `cockpit.${DOMAIN}`
- `wg.${DOMAIN}`

The Traefik dashboard, Traefik metrics, `pmproxy`, Grafana, and Valkey are loopback-only and have no DNS records or Traefik routes.

## 2. OCI network rules

Ingress:

| Port  | Protocol | Source    | Purpose                                      |
| ----- | -------- | --------- | -------------------------------------------- |
| 80    | TCP      | 0.0.0.0/0 | HTTP, redirected to HTTPS by Traefik         |
| 443   | TCP      | 0.0.0.0/0 | HTTPS through Traefik                        |
| 51820 | UDP      | 0.0.0.0/0 | WireGuard VPN                                |
| 22    | TCP      | Admin IP  | SSH, initial setup and emergency access only |

Do not expose 3000, 6379, 8080, 8082, 9090, 9091, 44322, or 51821 publicly.

## 3. DNS records

| Name                | Type | Value              | Proxy                |
| ------------------- | ---- | ------------------ | -------------------- |
| `cockpit.${DOMAIN}` | A    | Instance public IP | DNS Only, grey cloud |
| `auth.${DOMAIN}`    | A    | Instance public IP | DNS Only, grey cloud |
| `wg.${DOMAIN}`      | A    | Instance public IP | DNS Only, grey cloud |
| `${DOMAIN}`         | A    | Instance public IP | Orange or grey cloud |
| `*.${DOMAIN}`       | A    | Instance public IP | DNS Only, grey cloud |

Admin subdomains must be DNS Only. Cloudflare proxying makes Cloudflare IPs appear as the request source and bypasses the `ipAllowList` VPN check.

## 4. OCI Vault secrets

| Secret name                | Purpose                         | Variable                |
| -------------------------- | ------------------------------- | ----------------------- |
| `traefik-cloudflare-token` | ACME DNS-01 challenge           | `${CF_SECRET_OCID}`     |
| `authelia-admin-password`  | Initial Authelia admin password | `${AUTH_SECRET_OCID}`   |
| `wg-easy-admin-password`   | Initial wg-easy admin password  | `${WG_SECRET_OCID}`     |
| `grafana-admin-password`   | Grafana admin password          | `${GRAFANA_SECRET_OCID}` |
| `alert-webhook-url`        | HTTPS alert delivery webhook    | `${ALERT_WEBHOOK_SECRET_OCID}` |
| `alert-heartbeat-url`      | External heartbeat endpoint     | `${ALERT_HEARTBEAT_SECRET_OCID}` |

IAM policy:

```text
matching_rule = "instance.compartment.id = '<compartment-ocid>'"

Allow dynamic-group <dynamic-group-name> to read secret-family in compartment <compartment-name>
```

## 5. Persistent storage layout

Cloud-init detects the block device in this order: `/dev/oracleoci/oraclevdb`, `/dev/sdb`, `/dev/vdb`. It mounts the volume by UUID in `/etc/fstab`.

```text
/data/
├── traefik/
│   └── letsencrypt/         # acme.json
├── authelia/
│   ├── config/              # configuration and users database
│   ├── db/                  # SQLite database
│   └── env                  # secrets, PUID/PGID, and UMASK, mode 0600
├── apps/                    # application deployment manifests
├── containers/
│   ├── wg-easy/             # WireGuard keys and peer data, owner 300000
│   └── <app-name>/          # per-application data
├── monitoring/
│   ├── grafana/             # Grafana database and state, owner grafana
│   ├── valkey/              # PCP history, owner valkey, history profile only
│   └── alerting/            # Alerting webhook and heartbeat secrets, owner alerting
└── logs/
    └── traefik/             # Traefik access and error logs
```

Symlinks:

```text
/etc/traefik/letsencrypt  ->  /data/traefik/letsencrypt
/var/log/traefik          ->  /data/logs/traefik
```

Authelia and wg-easy bind-mount their data directly from `/data/`. `/data/authelia` is owned by `authelia:authelia`. `/data/containers/wg-easy` is owned by host UID and GID `300000`.

`/data/monitoring/grafana` is owned by `grafana:grafana`. `/data/monitoring/valkey` is owned by `valkey:valkey` and exists only in the `history` profile. `/data/monitoring/alerting` is owned by `alerting:alerting`. The monitoring directories use the `var_lib_t` SELinux type.

### 5.1 Service accounts and Quadlet paths

| Account  | Host user    | ID mapping                             | Service                                         |
| -------- | ------------ | -------------------------------------- | ----------------------------------------------- |
| authelia | System user  | Subordinate `400000-465535`            | Rootless Quadlet user unit                      |
| alerting | System user  | None                                   | Native systemd alerting services and timers     |
| traefik  | System user  | None                                   | Native systemd service                          |
| wg-easy  | No host user | Container root to host `300000-365535` | Rootful Quadlet system unit in a user namespace |

Authelia's user manager starts at boot through lingering. Its Quadlet unit is `/etc/containers/systemd/users/<authelia-uid>/authelia.container`. The wg-easy unit is `/etc/containers/systemd/wg-easy.container`. The template installs both units. A deployment test must prove generation and startup.

What persists across VM replacement:

1. Cloud-init detects the existing XFS filesystem and skips formatting.
2. WireGuard reads the existing private key from `/data/containers/wg-easy/`.
3. Traefik reads the existing `acme.json`.
4. Authelia reads its existing SQLite database.

The OS, Traefik binary, and container images are recreated.

## 6. Reserved ports

| Port  | Service                              |
| ----- | ------------------------------------ |
| 80    | Traefik HTTP                         |
| 443   | Traefik HTTPS                        |
| 3000  | Grafana, loopback                    |
| 6379  | Valkey, loopback, history profile    |
| 8080  | Traefik dashboard and API, loopback  |
| 8082  | Traefik Prometheus metrics, loopback |
| 9090  | Cockpit, loopback                    |
| 9091  | Authelia                             |
| 44322 | PCP pmproxy, loopback                |
| 51820 | WireGuard, UDP                       |
| 51821 | wg-easy management UI                |

Alert delivery adds no reserved inbound port. The notifier and heartbeat use outbound TCP 443 only.

## 7. Host packages

The template installs these package groups.

| Package                 | Group      | Purpose                                      |
| ----------------------- | ---------- | -------------------------------------------- |
| `cockpit`               | Base       | Web console                                  |
| `cockpit-storaged`      | Base       | Storage management page                      |
| `cockpit-podman`        | Base       | Podman container management page             |
| `cockpit-pcp`           | Monitoring | Cockpit PCP metrics page                     |
| `jq`                    | Base       | JSON payload and ACME state parsing          |
| `pcp`                   | Monitoring | Performance Co-Pilot collector               |
| `pcp-zeroconf`          | Monitoring | `pmlogger` and default archive setup         |
| `pcp-pmda-podman`       | Monitoring | Rootful container metrics                    |
| `pcp-pmda-openmetrics`  | Monitoring | Traefik and application OpenMetrics ingestion |
| `grafana`               | Live       | Grafana OSS server                           |
| `grafana-pcp`           | Live       | PCP Vector and Valkey datasources            |
| `valkey`                | History    | PCP `pmseries` history store                 |

`pmproxy`, `pmie`, and the two PMDAs are part of the PCP data plane and are not optional in the `live` or `none` profile.

## 8. Monitoring profiles

This section is the canonical statement of monitoring requirements. ADR-010 records the decision. The deployment, operations, and verification documents refer to this section.

### 8.1 Profile selection

`${MONITORING_PROFILE}` selects the monitoring profile:

| Value     | Grafana | Valkey | PCP | Intended use                                      |
| --------- | ------- | ------ | --- | ------------------------------------------------- |
| `none`    | No      | No     | Yes | Minimal resource use, PCP command-line tools only |
| `live`    | Yes     | No     | Yes | Default single local view with live metrics       |
| `history` | Yes     | Yes    | Yes | Live view plus PCP `pmseries` history             |

The default in `.env.example` is `live`. The profile is a template variable and must be passed to `envsubst`.

### 8.2 Capacity minimums

These are architecture-neutral minimums. They do not describe the current OCI shape.

| Profile   | Total RAM | vCPU | Free disk | Notes                                               |
| --------- | --------- | ---- | --------- | --------------------------------------------------- |
| `live`    | 4 GB      | 2    | 2 GB      | One operator and a small dashboard set              |
| `history` | 6 GB      | 2    | 5 GB      | Adds Valkey, PCP history, and larger archive growth |

The live profile fits a 2 OCPU and 4 GB instance. The history profile requires a 6 GB instance. Grafana's published minimum is 512 MB, but the profile minimum includes PCP, the operating system, and normal service headroom.

### 8.3 PCP data plane

| Component             | Role                                                        |
| --------------------- | ----------------------------------------------------------- |
| `pmcd`                | PCP collector daemon                                        |
| `pmlogger`            | Archive logger                                              |
| `pmproxy`             | Prometheus-compatible endpoint and `pmseries` query service |
| `pcp-pmda-podman`     | Rootful Podman container metrics                            |
| `pcp-pmda-openmetrics` | Traefik and application `/metrics` ingestion               |
| `pmie`                | Local inference and alert evaluation                        |

`pmproxy` binds to `127.0.0.1:44322`. It is the only Prometheus-compatible endpoint. An external Prometheus server can scrape it later through a secure tunnel. No external server is deployed now.

Alert delivery uses a dedicated `pcp-alert-pmie.service` with the same `pmie` binary. Section 9 is the canonical statement of alert thresholds, units, timers, and secrets.

The OpenMetrics PMDA reads `http://127.0.0.1:8082/metrics` through `/etc/pcp/openmetrics/traefik.url`. The Podman PMDA requires `podman.socket`. It collects rootful container metrics only. Rootless Authelia and rootless application containers are not included. Use Authelia health checks, application OpenMetrics, journald, and on-demand `podman stats` for those workloads.

### 8.4 Live profile

The live profile installs `grafana` and `grafana-pcp`. It provides one local Grafana instance with the bundled PCP Vector dashboards.

| Item            | Value                                      |
| --------------- | ------------------------------------------ |
| Listener        | `127.0.0.1:3000`                           |
| Configuration   | `/etc/grafana/grafana.ini`                 |
| Provisioning    | `/etc/grafana/provisioning/`               |
| Dashboard files | `/etc/grafana/dashboards/`                 |
| State           | `/data/monitoring/grafana`                 |
| Password        | OCI Vault secret `grafana-admin-password`  |
| Systemd unit    | `grafana-server.service`                   |
| Systemd drop-ins | `/etc/systemd/system/grafana-server.service.d/` |

Grafana loads the PCP plugin from the `grafana-pcp` RPM. The RPM does not include plugin signatures, so `/etc/grafana/grafana.ini` allows the PCP plugin IDs explicitly. Do not add other unsigned plugins to that list.

Systemd drop-ins under `/etc/systemd/system/grafana-server.service.d/` load `/data/monitoring/grafana/env` and grant write access to `/data/monitoring/grafana`.

### 8.5 History profile

The history profile adds `valkey` and PCP `pmseries` history. It includes everything in the live profile.

| Item          | Value                                      |
| ------------- | ------------------------------------------ |
| Listener      | `127.0.0.1:6379`                           |
| Configuration | `/etc/valkey/valkey.conf`                  |
| State         | `/data/monitoring/valkey`                  |
| Systemd unit  | `valkey.service`                           |
| Systemd drop-in | `/etc/systemd/system/valkey.service.d/data.conf` |
| Memory cap    | 512 MB with `noeviction`                   |

Oracle Linux 9 AppStream provides `grafana-pcp` 5.1.1. That version exposes the PCP Redis datasource, which is compatible with Valkey. The provisioned datasource is named PCP Valkey and uses the PCP Redis plugin type.

A full history store can refuse writes when it reaches the memory cap. Monitor `valkey-cli info memory` and increase the cap only after increasing total RAM. The history store is additional state and must be included in a backup or explicitly excluded.

### 8.6 Exposure and access

Grafana, Valkey, `pmproxy`, and raw metrics are loopback-only. Do not create Traefik routes for them. Do not open ports 3000, 6379, or 44322 in firewalld or the OCI network rules.

Access Grafana, Traefik metrics, and `pmproxy` through SSH local port forwarding:

```bash
ssh -L 3000:127.0.0.1:3000 \
  -L 8080:127.0.0.1:8080 \
  -L 8082:127.0.0.1:8082 \
  -L 44322:127.0.0.1:44322 \
  opc@<instance-public-ip>
```

Then open `http://localhost:3000`. Valkey access is for local administration only. Use `valkey-cli -h 127.0.0.1` on the instance.

### 8.7 State and recovery

Grafana state is stored under `/data/monitoring/grafana`. Valkey state is stored under `/data/monitoring/valkey` when the history profile is active. Both paths are on the block volume and survive VM replacement when the volume is attached and mounted.

The Grafana environment file is `/data/monitoring/grafana/env`, mode `0600`, owner `grafana:grafana`. Cloud-init creates it from OCI Vault on first boot and does not overwrite an existing file.

### 8.8 Verification

Run these checks on the instance after deployment:

```bash
systemctl is-active pmcd pmlogger pmproxy
curl -fsS http://127.0.0.1:44322/metrics >/dev/null
pminfo -f containers.name
pminfo -f openmetrics.control
sudo ss -ltnp | grep -E ':3000|:44322|:6379'
```

For the live profile, also run:

```bash
systemctl is-active grafana-server
curl -fsS http://127.0.0.1:3000/api/health
```

For the history profile, also run:

```bash
systemctl is-active valkey
valkey-cli -h 127.0.0.1 ping
```

The expected `valkey-cli` response is `PONG`. The expected Grafana health response contains `"database": "ok"`.

## 9. Alert delivery

This section is the canonical statement of alert delivery requirements. ADR-011 records the decision.

### 9.1 Components

| Component | Role | Identity |
| --- | --- | --- |
| `pcp-alert-pmie.service` | Evaluates the `pmie` threshold rules | `alerting` |
| `pcp-alert-notify@.service` | Sends a unit failure alert | `alerting` |
| `pcp-service-check.service` | Checks core units, Traefik health, and Authelia health | `alerting` |
| `pcp-cert-check.service` | Checks the earliest certificate expiry | `root`, hardened |
| `pcp-heartbeat.service` | Sends the external heartbeat | `alerting` |

The `pmie` rules are in `/etc/pcp/pmie/stack-alerts.pmie`. The service list is `/etc/pcp/alerting/services.list`. The notifier is `/usr/local/libexec/stack-alerting`.

`pcp-cert-check.service` is the only alerting component that runs as root. This is a narrow one-shot exception because `/data/traefik/letsencrypt/acme.json` contains private key material and remains root-only. The unit drops all capabilities, uses `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateDevices`, `PrivateTmp`, a system call filter, and a read-only `/data` mount. It writes only deduplication state under `/var/lib/stack-alerting`.

### 9.2 Thresholds and timers

| Check | Threshold or interval | Timer |
| --- | --- | --- |
| Filesystem use | Above 85 percent | `pmie`, every 2 minutes |
| One-minute load | Above 4 | `pmie`, every 2 minutes |
| Available memory | Below 512 MB | `pmie`, every 2 minutes |
| Core services | Inactive | `pcp-service-check.timer`, every 2 minutes |
| Traefik health | `/ping` failure | `pcp-service-check.timer`, every 2 minutes |
| Authelia health | `/api/health` failure | `pcp-service-check.timer`, every 2 minutes |
| Certificate expiry | Below 14 days | `pcp-cert-check.timer`, daily |
| External heartbeat | No heartbeat for the provider interval | `pcp-heartbeat.timer`, every 5 minutes |

`pmie` deduplicates a persistent condition with a 30-minute cooldown. Service checks alert on a transition to failure and send a recovery on the transition back to healthy.

### 9.3 Secrets

| Secret name | Runtime file | Owner and mode |
| --- | --- | --- |
| `alert-webhook-url` | `/data/monitoring/alerting/env` | `alerting:alerting`, `0600` |
| `alert-heartbeat-url` | `/data/monitoring/alerting/env` | `alerting:alerting`, `0600` |

The webhook URL must use HTTPS. The heartbeat URL must use HTTPS. The runtime file contains both values. Do not store either value in a tracked file.

### 9.4 Exposure

Alert delivery adds no inbound port and no Traefik route. The only network flow is outbound HTTPS to the webhook receiver and the heartbeat provider. The external provider alerts when the heartbeat stops.

### 9.5 Verification

```bash
systemctl is-active pcp-alert-pmie pcp-service-check.timer pcp-cert-check.timer pcp-heartbeat.timer
sudo runuser -u alerting -- pmie -C -c /etc/pcp/pmie/stack-alerts.pmie
ls -l /data/monitoring/alerting/env
systemctl list-timers pcp-service-check.timer pcp-cert-check.timer pcp-heartbeat.timer
```

A test alert requires a webhook receiver. `sudo systemctl start pcp-alert-notify@test.service` sends one alert. A stopped-instance test proves the external heartbeat.

## Related documents

- Design: `docs/architecture.md`
- Monitoring decision: `docs/decisions/010-monitoring-presentation.md`
- Alert delivery decision: `docs/decisions/011-alert-delivery.md`
- Deployment: `docs/guides/getting-started.md`
- Operations: `docs/guides/operations.md`
- Traefik reference: `docs/reference/traefik.md`
- Application manifest reference: `docs/reference/application-manifest.md`
