---
name: "Getting Started"
description: |
  End-to-end tutorial for provisioning the OCI secure stack from a clean Oracle Cloud Infrastructure environment.
status: draft
version: 1.6
updated: 2026-11-14
---

# Getting Started

This tutorial takes you from a clean OCI tenancy to a verified stack. It assumes you have an OCI account and a Cloudflare-managed DNS zone. It does not assume the stack has ever been deployed.

The design is described in `docs/architecture.md`. The current implementation is not yet proven in a deployment. See `docs/process/project-status.md` before treating any claim as verified.

## 1. Prerequisites

All of the following must exist before the instance is launched. Cloud-init cannot create them.

- An OCI VCN and subnet with the rules in section 2.
- An OCI compute instance with Oracle Linux 9. AMD and ARM shapes are supported.
- A block volume attached as paravirtualized, 50 GB minimum.
- An instance dynamic group and IAM policy that allow `read secret-family` in the Vault compartment.
- An OCI Vault with five mandatory secrets and one optional Grafana secret for the `live` or `history` profile.
- A Cloudflare zone and an API token with `Zone → DNS → Edit` permission on that zone.
- DNS records for every hostname in section 5.
- A workstation with `yq` v4 and `envsubst` for rendering the deployment file.
- Capacity for the selected monitoring profile. The `live` profile needs 4 GB RAM, 2 vCPU, and 2 GB free disk. The `history` profile needs 6 GB RAM, 2 vCPU, and 5 GB free disk. See `docs/reference/infrastructure.md` section 8.

### Free Tier fit

The stack targets Oracle Cloud Always Free. As of 2026-11-13, Oracle documents two AMD Micro instances, an Ampere A1 allowance equivalent to two OCPUs and 12 GB of memory, and 200 GB of block storage shared with boot volumes. Oracle publishes the current figures in [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm). One instance with the default 50 GB boot volume and a 50 GB block volume fits the documented allowance. The minimum practical shape is not yet verified. Confirm the allowance in the OCI console before provisioning. A 2 OCPU and 4 GB instance fits the `live` monitoring profile. The `history` profile needs 6 GB. If the selected shape has less memory, set `MONITORING_PROFILE=none` or leave the UI disabled.

SSH hardening: Oracle Linux 9 OCI images disable password authentication by default. Verify before exposing port 22:

```bash
sudo grep PasswordAuthentication /etc/ssh/sshd_config
```

The expected value is `PasswordAuthentication no`. Close port 22 after the first WireGuard peer is added. Ongoing management uses Cockpit over the VPN. Emergency shell access is available through the OCI Bastion Service or the OCI Console Connection.

## 2. OCI network rules

Allow inbound traffic only for the following ports.

| Port  | Protocol | Source    | Purpose                                      |
| ----- | -------- | --------- | -------------------------------------------- |
| 80    | TCP      | 0.0.0.0/0 | HTTP, redirected to HTTPS by Traefik         |
| 443   | TCP      | 0.0.0.0/0 | HTTPS through Traefik                        |
| 51820 | UDP      | 0.0.0.0/0 | WireGuard VPN                                |
| 22    | TCP      | Admin IP  | SSH, initial setup and emergency access only |

Do not expose the Traefik dashboard, raw metrics, `pmproxy`, Grafana, Valkey, Cockpit, Authelia, or wg-easy directly.

## 3. Configure variables

The template uses `${VARIABLE}` syntax for site-specific values. All other `${...}` references inside `runcmd` blocks are shell variables and must remain unsubstituted.

| Variable                         | Description                                             | Example                       |
| -------------------------------- | ------------------------------------------------------- | ----------------------------- |
| `${DOMAIN}`                      | Base domain for all subdomains                          | `example.com`                 |
| `${ACME_EMAIL}`                  | Email for Let's Encrypt expiry notices                  | `ops@example.com`             |
| `${ADMIN_EMAIL}`                 | Authelia admin user email                               | `admin@example.com`           |
| `${CF_SECRET_OCID}`              | OCID of the Cloudflare token secret in OCI Vault        | `ocid1.vaultsecret.oc1..xxxx` |
| `${AUTH_SECRET_OCID}`            | OCID of the Authelia admin password secret in OCI Vault | `ocid1.vaultsecret.oc1..yyyy` |
| `${WG_SECRET_OCID}`              | OCID of the wg-easy admin password secret in OCI Vault  | `ocid1.vaultsecret.oc1..zzzz` |
| `${GRAFANA_SECRET_OCID}`         | OCID of the Grafana admin password secret in OCI Vault  | `ocid1.vaultsecret.oc1..gggg` |
| `${ALERT_WEBHOOK_SECRET_OCID}`   | OCID of the alert webhook secret in OCI Vault           | `ocid1.vaultsecret.oc1..aaaa` |
| `${ALERT_HEARTBEAT_SECRET_OCID}` | OCID of the alert heartbeat secret in OCI Vault         | `ocid1.vaultsecret.oc1..bbbb` |
| `${MONITORING_PROFILE}`          | Monitoring profile: `live`, `history`, or `none`        | `live`                        |

`${GRAFANA_SECRET_OCID}` is required when `${MONITORING_PROFILE}` is `live` or `history`. The alert secret OCIDs are required in every profile.

The following hostnames are derived from `${DOMAIN}`:

- `auth.${DOMAIN}` for the Authelia portal
- `cockpit.${DOMAIN}` for Cockpit
- `wg.${DOMAIN}` for wg-easy

The Traefik dashboard, Traefik metrics, `pmproxy`, Grafana, and Valkey are loopback-only and have no DNS records or Traefik routes.

Create a `.env` file. Never commit it.

```bash
DOMAIN=example.com
ACME_EMAIL=ops@example.com
ADMIN_EMAIL=admin@example.com
CF_SECRET_OCID=ocid1.vaultsecret.oc1..xxxx
AUTH_SECRET_OCID=ocid1.vaultsecret.oc1..yyyy
WG_SECRET_OCID=ocid1.vaultsecret.oc1..zzzz
GRAFANA_SECRET_OCID=ocid1.vaultsecret.oc1..gggg
ALERT_WEBHOOK_SECRET_OCID=ocid1.vaultsecret.oc1..aaaa
ALERT_HEARTBEAT_SECRET_OCID=ocid1.vaultsecret.oc1..bbbb
MONITORING_PROFILE=live
```

## 4. Create OCI Vault secrets

The cloud-init script fetches five mandatory secrets and the Grafana secret at first boot with Instance Principal authentication. No credentials are embedded in the template.

### 4.1 IAM policy

Create a dynamic group for the instance, then create a policy:

```text
matching_rule = "instance.compartment.id = '<compartment-ocid>'"

Allow dynamic-group <dynamic-group-name> to read secret-family in compartment <compartment-name>
```

### 4.2 Cloudflare API token

This token is used by Traefik for DNS-01 ACME challenges.

1. In Cloudflare, go to **My Profile → API Tokens → Create Token → Create Custom Token**.
2. Set permission `Zone → DNS → Edit`.
3. Set Zone Resources to `Include → Specific zone → <zone name>`.
4. Optionally restrict the token to the instance public IP.
5. Copy the token. It is shown only once.

In OCI Vault:

1. Go to **Security → Vault → Secrets → Create Secret**.
2. Name it `traefik-cloudflare-token`.
3. Paste the Cloudflare token as the secret content.
4. Copy the secret OCID. This is `${CF_SECRET_OCID}`.

### 4.3 Authelia admin password

This is the initial Authelia admin password. Authelia hashes it and stores it in its SQLite database on the block volume. The secret is only needed for bootstrapping.

1. Create a Vault secret named `authelia-admin-password`.
2. Use the chosen password as plain text.
3. Copy the secret OCID. This is `${AUTH_SECRET_OCID}`.

The Authelia admin user is independent of the OS `opc` user and of Cockpit PAM authentication.

### 4.4 wg-easy admin password

This is the initial wg-easy web UI admin password. It is processed only on the first container start.

1. Create a Vault secret named `wg-easy-admin-password`.
2. Use the chosen password as plain text.
3. Copy the secret OCID. This is `${WG_SECRET_OCID}`.

Cloud-init processes the `INIT_USERNAME` and `INIT_PASSWORD` values only on first boot. The credentials are stored in wg-easy's SQLite database on the block volume. The Vault secret is needed again only when bootstrapping a fresh instance.

### 4.5 Grafana admin password

This secret is required when `MONITORING_PROFILE` is `live` or `history`.

1. Create a Vault secret named `grafana-admin-password`.
2. Use the chosen password as plain text.
3. Copy the secret OCID. This is `${GRAFANA_SECRET_OCID}`.

Cloud-init writes the password to `/data/monitoring/grafana/env` with mode `0600` and owner `grafana:grafana`. It does not write the password to a tracked file or the system journal.

### 4.6 Alert webhook URL

This secret is required in every monitoring profile. It is the HTTPS endpoint that receives alert notifications.

1. Create a webhook receiver at the chosen provider.
2. Copy the full HTTPS webhook URL.
3. Create a Vault secret named `alert-webhook-url` with the URL as plain text.
4. Copy the secret OCID. This is `${ALERT_WEBHOOK_SECRET_OCID}`.

Cloud-init writes the value to `/data/monitoring/alerting/env` with mode `0600` and owner `alerting:alerting`. The URL is not written to a tracked file or the system journal.

### 4.7 External heartbeat URL

This secret is required in every monitoring profile. It is the HTTPS ping endpoint that proves the instance is alive.

1. Create a check at the chosen heartbeat provider.
2. Copy the full HTTPS ping URL.
3. Create a Vault secret named `alert-heartbeat-url` with the URL as plain text.
4. Copy the secret OCID. This is `${ALERT_HEARTBEAT_SECRET_OCID}`.

Cloud-init writes the value to `/data/monitoring/alerting/env` with mode `0600` and owner `alerting:alerting`. The same file contains the webhook URL. The URL is not written to a tracked file or the system journal.

The provider should alert when no heartbeat arrives for two consecutive five-minute intervals. The heartbeat does not replace the local checks. It detects a total instance or network loss.

### 4.8 Verify Cloudflare secret access after boot

Run this check after boot:

```bash
oci secrets secret-bundle get \
  --secret-id <CF_SECRET_OCID> \
  --query "data.secretBundleContent.content" \
  --raw-output | base64 -d
```

The command should print the Cloudflare token.

## 5. Create DNS records

All records must exist in Cloudflare before cloud-init runs. Traefik starts ACME challenges immediately on first start.

| Name                | Type | Value              | Proxy                |
| ------------------- | ---- | ------------------ | -------------------- |
| `cockpit.${DOMAIN}` | A    | Instance public IP | DNS Only, grey cloud |
| `auth.${DOMAIN}`    | A    | Instance public IP | DNS Only, grey cloud |
| `wg.${DOMAIN}`      | A    | Instance public IP | DNS Only, grey cloud |
| `${DOMAIN}`         | A    | Instance public IP | Orange or grey cloud |
| `*.${DOMAIN}`       | A    | Instance public IP | DNS Only, grey cloud |

Admin subdomains must always be DNS Only. Cloudflare proxying makes Cloudflare IPs appear as the request source, which bypasses the Traefik `ipAllowList` VPN check.

A wildcard record means new application services resolve without adding individual records. After a VM replacement, only the A record IP values need updating.

## 6. Render the deployment file

Create `.env` as described in section 3. Set `architecture` in `infra/manifest.yaml` to `amd64` or `arm64` to match the instance shape. If the architecture changes, run `tools/update-lock.sh` before rendering. The first cloud-init command checks the instance architecture and stops before host changes when it does not match. Render the component configuration into the cloud-config template, then substitute only the ten template variables. The validator and renderer require `yq` v4. Pass only the ten variables to `envsubst` so shell variables inside `runcmd` remain intact.

```bash
export $(cat .env | xargs)

tools/validate-manifest.sh
tools/render-config.sh \
  | envsubst '${DOMAIN} ${ACME_EMAIL} ${ADMIN_EMAIL} ${CF_SECRET_OCID} ${AUTH_SECRET_OCID} ${WG_SECRET_OCID} ${GRAFANA_SECRET_OCID} ${MONITORING_PROFILE} ${ALERT_WEBHOOK_SECRET_OCID} ${ALERT_HEARTBEAT_SECRET_OCID}' \
  > cloud-config.yaml
```

The output `cloud-config.yaml` is the file to paste into the OCI Console **User data** field. You can also pass it with the OCI CLI:

```bash
oci compute instance launch \
  --user-data-file cloud-config.yaml \
  ... # other flags
```

## 7. Launch the instance

1. Create the compute instance with Oracle Linux 9 and the desired shape.
2. Paste `cloud-config.yaml` into the **User data** field.
3. Attach the block volume as paravirtualized.
4. Confirm the VCN rules from section 2.
5. Wait for cloud-init to finish. First boot typically takes 5 to 10 minutes.

Check progress:

```bash
cloud-init status --long
sudo tail -f /var/log/cloud-init-output.log
```

To re-run cloud-init on an already provisioned instance:

```bash
sudo cloud-init clean --logs
sudo cloud-init init
sudo cloud-init modules --mode=config
sudo cloud-init modules --mode=final
```

The `runcmd` blocks are designed to be idempotent. Re-running must not reformat the block volume, duplicate `fstab` entries, or overwrite existing Authelia or wg-easy data.

## 8. Verify the deployment

Run the automated verification script from a checkout of this repository on the instance:

```bash
sudo ./infra/host/verify-stack.sh
```

Exit code `0` means all checks passed. Exit code `1` means one or more checks failed. The script covers boot volume expansion, cloud-init status, block volume mount, symlinks, service health, PCP export, optional Grafana and Valkey services, alert delivery, TLS certificates, WireGuard, SELinux, journal persistence, and firewall rules.

If a check fails, see `docs/guides/operations.md` for component checks and common failure patterns.

## 9. Bootstrap the first WireGuard peer

The wg-easy UI is behind the VPN, but a peer must exist before the VPN can be used. Use an SSH local port forward while port 22 is still open.

```bash
ssh -L 51821:127.0.0.1:51821 opc@<instance-public-ip>
```

Open `http://localhost:51821` in a browser. This connects directly to wg-easy and bypasses Traefik and the VPN restriction. Add the first peer, download the client configuration or scan the QR code, and connect WireGuard.

Verify that `https://wg.${DOMAIN}` works through the VPN after Authelia login. Then remove the bootstrap credentials from the wg-easy environment and restart the service:

```bash
sudo sed -i '/^INIT_USERNAME=/d;/^INIT_PASSWORD=/d' /data/containers/wg-easy/env
sudo systemctl restart wg-easy.service
```

Close port 22 after the first peer is verified. Use the OCI Bastion Service or Console Connection for emergency access.

## 10. Final checks

With WireGuard connected, open the routed admin services. Each should require Authelia login and then grant access:

- `https://cockpit.${DOMAIN}` for Cockpit
- `https://wg.${DOMAIN}` for wg-easy

Without WireGuard, both URLs must return `403 Forbidden` with no login prompt.

The Traefik dashboard, Traefik metrics, PCP `pmproxy`, and Grafana are not routed. Reach them through SSH local forwarding as described in `docs/guides/operations.md`:

```bash
ssh -L 3000:127.0.0.1:3000 \
  -L 8080:127.0.0.1:8080 \
  -L 8082:127.0.0.1:8082 \
  -L 44322:127.0.0.1:44322 \
  opc@<instance-public-ip>
```

Then open `http://localhost:8080/dashboard/`, `http://localhost:8082/metrics`, and `http://localhost:3000`. Log in to Grafana with the user `admin` and the `grafana-admin-password` value from OCI Vault.

Confirm that alert delivery works:

```bash
sudo systemctl start pcp-alert-notify@test.service
sudo systemctl status pcp-alert-pmie pcp-service-check.timer pcp-cert-check.timer pcp-heartbeat.timer
```

The webhook receiver must show one test alert. The external heartbeat provider must show a recent ping. A stopped-instance test is the only proof that the provider detects total loss.

If `MONITORING_PROFILE=history`, confirm the history service:

```bash
sudo valkey-cli -h 127.0.0.1 ping
```

The expected response is `PONG`.

## 11. If you are changing the stack

Before deploying a change, run the local validation commands in `docs/guides/operations.md`. For incremental testing, run the cloud-init phases and `runcmd` blocks manually. Do not use a production instance for first-time validation.

## Related documents

- Design: `docs/architecture.md`
- Operations: `docs/guides/operations.md`
- Application integration: `docs/guides/adding-apps.md`
- Infrastructure reference: `docs/reference/infrastructure.md`
- Current status: `docs/process/project-status.md`
- Acceptance checklist: `docs/process/acceptance-criteria.md`
