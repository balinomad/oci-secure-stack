---
name: "Operations"
description: |
  Operational runbook for verifying, testing, maintaining, backing up, replacing, and troubleshooting the OCI secure stack.
status: draft
version: 1.0
updated: 2026-11-12
---

# Operations

This runbook covers a running stack and changes to it. It is written for an operator with SSH access and OCI console access.

The design is described in `docs/architecture.md`. The deployment procedure is in `docs/guides/getting-started.md`. The acceptance checklist is `docs/process/acceptance-criteria.md`.

## 1. Validate changes before deployment

Run these checks locally before rendering or deploying a change.

### 1.1 YAML syntax

```bash
pip install yamllint
yamllint infra/cloud-init/cloud-config.example.yaml
```

`${VARIABLE}` placeholders are valid YAML string content and do not cause errors.

### 1.2 Render and validate the output

```bash
export $(cat .env | xargs)
envsubst '${DOMAIN} ${ACME_EMAIL} ${ADMIN_EMAIL} ${CF_SECRET_OCID} ${AUTH_SECRET_OCID} ${WG_SECRET_OCID}' \
  < infra/cloud-init/cloud-config.example.yaml > cloud-config.yaml

yamllint cloud-config.yaml

# Should return nothing if all variables were substituted
grep '\${' cloud-config.yaml
```

### 1.3 Shell content

Extract and lint the `runcmd` shell blocks:

```bash
grep -A 1000 '^runcmd:' cloud-config.yaml \
  | grep -v '^runcmd:' \
  | sed 's/^  - |//' \
  | sed 's/^  - //' \
  | shellcheck -s bash -
```

This is approximate. For a thorough check, copy individual `runcmd` blocks into temporary `.sh` files and run `shellcheck` on each.

### 1.4 cloud-init schema

```bash
cloud-init schema --config-file cloud-config.yaml
```

This validates the cloud-init key structure but does not execute anything. It requires `cloud-init` locally.

### 1.5 Variable completeness

Verify that all six variables are present and non-empty:

```bash
while IFS='=' read -r key value; do
  [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
  if [[ -z "$value" ]]; then
    echo "EMPTY: $key"
  else
    echo "OK:    $key"
  fi
done < .env
```

## 2. Test a change incrementally

The cloud-init script cannot be unit tested in isolation. It provisions OS state, packages, systemd units, and services that exist only on a live Oracle Linux 9 instance. The safe approach is to validate locally, then run the cloud-init phases and `runcmd` blocks manually on a disposable instance.

1. Launch an OCI instance with Oracle Linux 9 and an attached block volume.
2. Leave the User Data field empty.
3. SSH in as `opc`.
4. Run only the `write_files` and packages phases:

```bash
sudo cloud-init init
sudo cloud-init modules --mode=config
# Do not run: sudo cloud-init modules --mode=final
```

5. Copy each `runcmd` block from `cloud-config.yaml` and run it as root. Stop at the first error and resolve it before continuing.

| Step | Block                             | Verify after                                                                                                           |
| ---- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| 1    | Boot volume expansion             | `df -h /` shows the expanded root filesystem                                                                           |
| 2    | Block storage setup               | `mountpoint /data` exits 0; `cat /etc/fstab` shows a UUID entry                                                        |
| 3    | Persistent directory structure    | `ls /data/` shows the expected subdirectories                                                                          |
| 4    | Symlinks                          | `readlink -f /etc/traefik/letsencrypt` returns `/data/traefik/letsencrypt`                                             |
| 5    | Traefik directories and ownership | `ls -la /etc/traefik/` shows `traefik:traefik` ownership                                                               |
| 6    | Container tools                   | `podman --version`; `podman images` shows Authelia and wg-easy pulled                                                  |
| 7    | Vault secrets                     | `/etc/traefik/env` contains `CF_DNS_API_TOKEN`; `/run/authelia-bootstrap.tmp` exists                                   |
| 8    | Authelia bootstrap                | `/data/authelia/env`, `/data/authelia/config/configuration.yml`, and `/data/authelia/config/users_database.yaml` exist |
| 9    | wg-easy environment               | `/data/containers/wg-easy/env` exists; `/run/wg-bootstrap.tmp` does not exist                                          |
| 10   | SELinux contexts                  | `ausearch -m avc -ts recent \| grep traefik` returns nothing                                                           |
| 11   | System hardening                  | `getenforce` returns `Enforcing`; `systemctl is-active auditd` returns `active`                                        |
| 12   | Traefik binary                    | `/usr/local/bin/traefik version` prints a version                                                                      |
| 13   | IP forwarding                     | `sysctl net.ipv4.ip_forward` returns `1`                                                                               |
| 14   | Journal persistence               | `/var/log/journal/` exists                                                                                             |
| 15   | Firewall rules                    | `firewall-cmd --list-all` shows HTTP, HTTPS, and 51820/UDP                                                             |
| 16   | Service start                     | `systemctl is-active traefik authelia wg-easy cockpit pmcd pmlogger`                                                   |

Once all blocks pass, run `sudo ./scripts/host/verify-stack.sh`.

## 3. Verify a deployment

The `scripts/host/verify-stack.sh` script runs the checks in sequence and produces a pass or fail summary. It covers boot volume expansion, cloud-init status, block volume mount, symlinks, service health, TLS certificates, WireGuard, SELinux, journal persistence, and firewall rules.

From a checkout of this repository on the instance:

```bash
sudo ./scripts/host/verify-stack.sh
```

Exit code `0` means all checks passed. Exit code `1` means one or more checks failed.

WireGuard is checked on the server side only. After the first peer is added, verify end-to-end connectivity from the client:

```bash
sudo wg-quick up wg0
ping 10.0.0.1
sudo podman exec wg-easy wg show
```

The `latest handshake` field should show a recent timestamp. The interface lives in the wg-easy container namespace, so `wg show` on the host is not a valid check.

With WireGuard connected, open each admin URL. Each should redirect to Authelia and grant access after password plus TOTP. Without WireGuard, all admin URLs should return `403 Forbidden` with no login prompt.

## 4. Component health checks

### 4.1 Traefik

```bash
sudo systemctl status traefik
sudo journalctl -u traefik.service -n 50
sudo ss -ltnp | grep -E ':80|:443|:8080|:8082'
curl -fsS http://127.0.0.1:8080/ping
curl -fsS http://127.0.0.1:8082/metrics
```

Expected listeners: `:80`, `:443`, `127.0.0.1:8080`, and `127.0.0.1:8082`.

Validate the static configuration:

```bash
/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yaml --help > /dev/null
```

Check the HTTP to HTTPS redirect:

```bash
curl -I http://auth.example.com
```

Expected: `301` redirect to HTTPS.

### 4.2 Authelia

```bash
sudo podman ps | grep authelia
sudo journalctl -u authelia.service -n 50
curl -s http://127.0.0.1:9091/api/health
sudo podman exec authelia authelia validate-config --config /config/configuration.yml
```

Expected health response: `{"status":"OK"}`.

### 4.3 wg-easy and WireGuard

```bash
sudo podman ps | grep wg-easy
sudo journalctl -u wg-easy.service -n 50
sudo podman exec wg-easy wg show
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:51821
```

Expected: interface `wg0`, a public key, listening port `51820`, and HTTP `200` from the local management UI.

### 4.4 Cockpit

```bash
systemctl is-active cockpit.socket
curl -sk -o /dev/null -w "%{http_code}" http://127.0.0.1:9090
```

Expected: `active` and HTTP `200`.

### 4.5 TLS certificate issuance

```bash
sudo journalctl -u traefik.service -f | grep -i "acme\|certificate\|challenge\|cloudflare"

watch -n 5 "stat -c '%s bytes' /data/traefik/letsencrypt/acme.json 2>/dev/null || echo 'not yet created'"
```

Once `acme.json` is larger than 1 KB, inspect the certificate domains:

```bash
cat /data/traefik/letsencrypt/acme.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for resolver, content in data.items():
    for cert in content.get('Certificates', []):
        print(cert.get('domain', {}).get('main', 'unknown'))
"
```

Certificate issuance can take 1 to 3 minutes on first boot. If `acme.json` remains small after 5 minutes, verify the Cloudflare token and the DNS records.

### 4.6 SELinux

```bash
sudo ausearch -m avc -ts today | grep -E "traefik|authelia|podman"
ls -Z /usr/local/bin/traefik
```

Expected context for the Traefik binary: `system_u:object_r:bin_t:s0`.

If denials exist, generate a local policy:

```bash
sudo ausearch -m avc -ts today | audit2allow -M local-stack
sudo semodule -i local-stack.pp
```

### 4.7 Access the dashboard and metrics

The Traefik dashboard and metrics are loopback-only. Use SSH local port forwarding:

```bash
ssh -L 8080:127.0.0.1:8080 -L 8082:127.0.0.1:8082 opc@<instance-public-ip>
```

Then open `http://localhost:8080/dashboard/` for the dashboard and `http://localhost:8082/metrics` for metrics. Do not create Traefik routes for these endpoints. If they are routed as hostnames, findings F6 and F8 apply.

### 4.8 Manage WireGuard peers

Use the wg-easy UI at `https://wg.<domain>` over the VPN. Add one peer per device. Download the client configuration or scan the QR code.

wg-easy assigns client addresses sequentially from `10.0.0.2`. The server holds `10.0.0.1`.

Client configurations use `AllowedIPs = 0.0.0.0/0, ::/0` by default. Keep the full tunnel. Split-tunnel mode with `AllowedIPs = 10.0.0.0/24` does not work for admin hostnames. The client must map each hostname to `10.0.0.1` in its hosts file.

Revoke a lost or retired device immediately:

1. Open `https://wg.<domain>`.
2. Locate the peer and delete it.

The peer is removed from the running interface immediately. No restart is needed.

Get the server public key from the wg-easy admin panel or from the container:

```bash
sudo podman exec wg-easy wg show wg0 public-key
```

## 5. Common failure patterns

### Block volume not found

**Symptom:** `WARNING: No block device found` in cloud-init output and `/data` is not mounted.

**Cause:** The volume is not attached, or the device path differs from the probed paths.

**Fix:** Verify the attachment in the OCI Console. Check `lsblk` for the actual path and add it to the probe list.

### OCI Vault secret fetch fails

**Symptom:** cloud-init fails at the Vault step, or `/etc/traefik/env` contains a placeholder value.

**Causes and fixes:**

- Instance Principal is not configured. Verify the dynamic group and IAM policy.
- A secret OCID is wrong. Verify the values in `.env` against the OCI Console.
- `oci-cli` is not installed. Check the DNF step.

Test Instance Principal manually:

```bash
oci secrets secret-bundle get \
  --secret-id <CF_SECRET_OCID> \
  --query "data.secretBundleContent.content" \
  --raw-output | base64 -d
```

### Traefik fails to start

**Symptom:** `traefik.service` is failed and the journal shows configuration errors.

**Causes:**

- YAML syntax error in `traefik.yml` or a dynamic config file.
- SELinux denial on configuration files.
- Port 80 or 443 already in use.

**Checks:**

```bash
sudo journalctl -u traefik.service -n 100
sudo ausearch -m avc -ts recent
sudo ss -tlnp | grep -E ':80|:443'
```

### Authelia container fails to start

**Symptom:** `authelia.service` is failed.

**Causes:**

- `/data/authelia/config/configuration.yml` was not copied from the template.
- The secret environment variable names are wrong.
- The image was not pulled.

**Checks:**

```bash
sudo journalctl -u authelia.service -n 50
sudo podman images | grep authelia
ls -l /data/authelia/config/
```

### TLS certificates are not issued

**Symptom:** `acme.json` is smaller than 1 KB after 5 minutes.

**Causes:**

- DNS records do not exist or have not propagated.
- The Cloudflare token lacks `Zone → DNS → Edit`.
- The token was stored with a trailing newline.

**Checks:**

```bash
dig +short auth.example.com
sudo journalctl -u traefik.service | grep -i "acme\|cloudflare\|challenge\|error"
```

### WireGuard interface is not up

**Symptom:** `podman exec wg-easy wg show` fails and `wg-easy.service` is failed.

**Causes:**

- `NET_ADMIN` capability is missing.
- `net.ipv4.ip_forward` is not set.
- The wg-easy database was not initialised.

**Checks:**

```bash
sysctl net.ipv4.ip_forward
sudo journalctl -u wg-easy.service -n 50
sudo podman logs wg-easy
```

### SELinux blocks a service

**Symptom:** A service starts but behaves incorrectly, and `ausearch` shows denials.

**Fix:**

```bash
sudo ausearch -m avc -ts recent | audit2allow -M local-stack
sudo semodule -i local-stack.pp
sudo systemctl restart traefik.service
```

If denials persist, capture the full `ausearch` output and review the SELinux file contexts for the OCI image version.

## 6. Certificate renewal

Renewal is automatic. Traefik renews through Cloudflare DNS-01 at least 30 days before expiry.

To force renewal after a domain change:

```bash
sudo systemctl stop traefik
sudo rm /data/traefik/letsencrypt/acme.json
sudo systemctl start traefik
```

A new `acme.json` is created on start and certificates are issued within minutes.

## 7. Update Traefik

The legacy manual update path is:

```bash
TRAEFIK_VERSION="v3.x.y"
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

curl -fsSL "https://github.com/traefik/traefik/releases/download/${TRAEFIK_VERSION}/traefik_${TRAEFIK_VERSION}_linux_${ARCH}.tar.gz" \
  | sudo tar -xz -C /usr/local/bin/ traefik

sudo systemctl restart traefik
traefik version
```

The hardened deployment uses a versioned binary layout under `/opt/traefik/releases` and a `traefik-update` script with checksum verification and rollback. The full unit, script, and release layout are in `docs/reference/traefik.md`.

Manual rollback:

```bash
ls -l /opt/traefik/releases
sudo ln -sfn /opt/traefik/releases/vOLD/traefik /opt/traefik/bin/traefik
sudo systemctl restart traefik
sudo systemctl status traefik
```

## 8. Update the OS, WireGuard, and the kernel

Apply operating system security updates regularly:

```bash
sudo dnf update --security
```

Reboot after a kernel, systemd, or WireGuard update.

```bash
sudo dnf update wireguard-tools
```

WireGuard is in-kernel on Oracle Linux 9. The kernel module is updated with the kernel package:

```bash
sudo dnf update kernel-uek
sudo reboot
```

## 9. Rotate secrets

### 9.1 Cloudflare token

1. Create a new token in Cloudflare.
2. Add a new secret version in OCI Vault.
3. Update the running instance:

```bash
NEW_TOKEN=$(oci secrets secret-bundle get \
  --secret-id <CF_SECRET_OCID> \
  --query "data.secretBundleContent.content" \
  --raw-output | base64 -d)
echo "CF_DNS_API_TOKEN=$NEW_TOKEN" | sudo tee /etc/traefik/env
sudo chmod 600 /etc/traefik/env
sudo chown traefik:traefik /etc/traefik/env
sudo systemctl restart traefik
```

### 9.2 Authelia admin password

1. Update the secret in OCI Vault.
2. Generate a new hash and update the users database:

```bash
NEW_PASS=$(oci secrets secret-bundle get \
  --secret-id <AUTH_SECRET_OCID> \
  --query "data.secretBundleContent.content" \
  --raw-output | base64 -d)
podman exec authelia authelia crypto hash generate argon2 --password "$NEW_PASS"
```

Update the resulting hash in `/data/authelia/config/users_database.yaml`. No Traefik restart is needed.

## 10. Replace the VM

1. Note the block volume OCID and attachment details.
2. Terminate the instance. The block volume detaches but is not deleted.
3. Provision a new instance with the same shape and OS. Use the rendered `cloud-config.yaml` as user data and attach the existing block volume as paravirtualized.
4. Update the Cloudflare A records to the new public IP.
5. Cloud-init detects the existing block volume data and skips destructive steps.
6. Services start with persistent state intact.

Total downtime is the interval between old instance termination and the new instance reaching `cloud-init status: done`, typically 5 to 8 minutes.

## 11. Backup and restore

The block volume holds all persistent state. If it is lost or corrupted, WireGuard keys, TLS certificates, the Authelia database, container data, and logs are lost. VM replacement does not protect against this.

Restic is the recommended tool. It is a single static binary, deduplicating, encrypted at rest, and compatible with OCI Object Storage through its S3-compatible API.

### 11.1 Setup

1. Create a private OCI Object Storage bucket.
2. Create an OCI Customer Secret Key under the user profile.
3. Store the key in OCI Vault as a fourth secret.

### 11.2 Backup commands

```bash
export AWS_ACCESS_KEY_ID="<oci-customer-secret-key-id>"
export AWS_SECRET_ACCESS_KEY="<oci-customer-secret-key>"
export RESTIC_PASSWORD="<restic-repository-password>"
export RESTIC_REPOSITORY="s3:https://<namespace>.compat.objectstorage.<region>.oraclecloud.com/<bucket>"

restic init
restic backup /data
restic snapshots
restic restore latest --target /data
```

### 11.3 Automate with systemd

Store Restic credentials in `/etc/restic/env` with mode `0600`, fetched from OCI Vault at boot following the Traefik pattern.

```ini
# /etc/systemd/system/restic-backup.service
[Unit]
Description=Restic Backup to OCI Object Storage
After=local-fs.target network-online.target
Requires=local-fs.target

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
ExecStart=/usr/local/bin/restic backup /data
ExecStartPost=/usr/local/bin/restic forget --keep-daily 7 --keep-weekly 4 --prune

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/restic-backup.timer
[Unit]
Description=Daily Restic Backup

[Timer]
OnCalendar=02:00
Persistent=true

[Install]
WantedBy=timers.target
```

### 11.4 Post-restore check

After a restore, start each affected application and confirm its health.

```bash
sudo systemctl start <app-name>
sudo systemctl status <app-name>
sudo journalctl -u <app-name> -n 50
```

A restore is verified only when the application reads its restored data and the service health check passes. Use a disposable environment for the first restore test.

## 12. Logs and log rotation

Traefik access logs are rotated by `/etc/logrotate.d/traefik`: daily, 14-day retention, compressed. Systemd journal logs are persistent in `/var/log/journal/` and managed by journald `SystemMaxUse`.

```bash
journalctl --disk-usage
sudo tail -f /data/logs/traefik/traefik.log
sudo tail -f /data/logs/traefik/access.log
```

## 13. Traefik configuration and ACME backup

Restic is the primary backup. A local secondary backup for root-filesystem Traefik configuration and ACME state can be created with `/usr/local/sbin/traefik-backup` and a daily timer. The script and unit are in `docs/reference/traefik.md`.

The local backup excludes `/etc/traefik/env`. Restore the Cloudflare token from OCI Vault. Restic covers `/data/`; it does not include `/etc/traefik/env`. Protect the Restic repository.

## 14. Audit and security checks

```bash
systemctl status traefik
getenforce
sudo firewall-cmd --list-all
sudo ss -ltnp | grep -E ':80|:443|:8080|:8082'
ls -l /opt/traefik/bin/traefik
ls -ld /data/traefik /data/logs/traefik /etc/traefik
ls -l /data/traefik/letsencrypt/acme.json
ls -l /etc/traefik/env
id traefik
sudo last -n 20
sudo ausearch -k traefik_config -ts today
sudo ausearch -k traefik_state -ts today
```

Expected posture:

- Traefik runs as `traefik`, not root and not an SSH user.
- `/data/traefik/letsencrypt/acme.json` is mode `0600`.
- `/etc/traefik/env` is mode `0600` and owned by `traefik:traefik`.
- `/opt/traefik` and `/etc/traefik` are owned by root.
- Dashboard and metrics are loopback-only.
- No Podman socket is mounted into Traefik.
- SELinux remains enforcing.
- Only ports 80, 443, 51820/UDP, and bootstrap SSH are exposed.
- The Cloudflare token is not present in `traefik.yml`.

## 15. Infrastructure as code

`infra/cloud-init/cloud-config.example.yaml` automates the OS layer, but the OCI VCN, subnet, security lists, block volume, Vault, and instance are currently provisioned manually. Terraform can complete the immutable infrastructure picture.

A minimal layout:

```text
terraform/
├── main.tf       # Provider config, VCN, subnet, security list
├── compute.tf    # Instance definition, cloud-init user_data reference
├── storage.tf    # Block volume and attachment
├── vault.tf      # Vault and secret definitions
├── dns.tf        # Cloudflare provider and DNS records
└── variables.tf  # Domain, region, compartment OCID
```

Terraform state should use OCI Object Storage as a remote backend. This is not part of v1.0 until ADR-007 is written.

## Related documents

- Design: `docs/architecture.md`
- Deployment: `docs/guides/getting-started.md`
- Application integration: `docs/guides/adding-apps.md`
- Infrastructure reference: `docs/reference/infrastructure.md`
- Traefik reference: `docs/reference/traefik.md`
- Acceptance checklist: `docs/process/acceptance-criteria.md`
- Issue log: `docs/process/issue-log.md`
