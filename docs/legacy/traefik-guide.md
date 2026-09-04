---
project: oci-secure-stack
name: Traefik Installation, Configuration and Maintenance Guide
version: 1.0
updated: 2026-09-01
---

# Traefik Installation, Configuration and Maintenance Guide

## Immediate Security Report

The following security issues were identified while aligning this document to the application integration guide.

1. **Metrics exposure risk**
   - The application integration guide mentions a Prometheus endpoint at `https://metrics.<domain>`.
   - Exposing Traefik metrics publicly is an information-disclosure risk.
   - This guide enables metrics only on `127.0.0.1:8082`.
   - If the metrics endpoint is exposed through Traefik, it must be protected by VPN and authentication, for example via the stack-provided `admin-chain`.

2. **Middleware dependencies**
   - `global-security-headers` is defined in this guide because it is pure Traefik configuration.
   - `admin-chain` and `wg-allowlist` are not fully defined here because they depend on Authelia and WireGuard.
   - Application route configs must not reference those middlewares until the stack has created them.

3. **Secret handling**
   - The Cloudflare API token must not be written into `traefik.yml`.
   - The token must be stored under `/data/traefik/traefik.env` and populated from OCI Vault.
   - The root filesystem is ephemeral; secrets must not be stored outside `/data/`.

4. **VM replacement**
   - The root filesystem is ephemeral.
   - Traefik installation, configuration, systemd units, scripts, logrotate config, and audit rules must be reproducible by cloud-init or the stack provisioning process.
   - Only state under `/data/` persists automatically.

## 1. Scope

This document covers:

- Traefik installation.
- Traefik static configuration.
- Traefik dynamic infrastructure configuration directly required by the proxy platform.
- Traefik security isolation.
- Traefik logging, metrics, backups, updates, and maintenance.
- Alignment with the application integration guide.

This document does not cover:

- Application containers.
- Application images.
- Application persistent data.
- Application-specific Traefik routers or services.
- Authelia installation or configuration.
- WireGuard installation or configuration.
- OCI Vault secret creation.
- Restic backup infrastructure itself.

## 2. Authoritative Alignment

Where the application integration guide and the previous standalone Traefik guide conflicted, the application integration guide is authoritative unless a security concern required a hardening change.

Aligned items:

- Dynamic configuration directory is `/etc/traefik/config/`.
- Traefik hot-reloads that directory.
- Canonical certificate resolver is `cloudflare`.
- ACME storage is persistent and placed under `/data/traefik/`.
- Traefik access logs are written to `/data/logs/traefik/access.log` in JSON format.
- Traefik Prometheus metrics are available internally on port `8082`.
- Persistent data is placed under `/data/`.
- VM replacement is acknowledged; root filesystem artifacts are ephemeral.
- Secrets are kept under `/data/`.
- Backup and restore expectations are aligned with `/data/` persistence.

Security hardening added:

- Access-log header redaction.
- Localhost-only dashboard.
- Localhost-only metrics entrypoint.
- No public exposure of metrics by default.
- Dedicated non-login runtime user.
- systemd sandboxing.
- File permission baseline.
- Audit rules.
- OCI Vault-compatible secret file location.

## 3. Design Decisions

### 3.1 Operating system

- Oracle Linux Server 9.8.
- Architecture: `aarch64` / ARM64.
- Oracle Cloud A1.Flex instances are ARM64.
- All Traefik binaries must be ARM64-compatible.

### 3.2 Containerization

Check whether Podman is installed, but do not install it solely for Traefik.

- Do not use Docker.
- Do not use Podman for Traefik unless containerization is mandatory.
- For a standalone reverse proxy, a native systemd service is simpler and has fewer moving parts.
- Application containers are managed separately with Podman Quadlet, as defined by the application integration guide.

### 3.3 Runtime user

Do not run Traefik as the SSH login user.

Use:

- Dedicated system user: `traefik`.
- Non-login shell.
- No sudo rights.
- Write access only to Traefik state and logs under `/data/`.

### 3.4 Configuration provider

Use the file provider.

- Provider directory: `/etc/traefik/config`.
- Hot reload enabled.
- No Podman socket.
- no backend container discovery.

Rationale:

- The Podman socket is a privileged interface.
- Backend application configuration is out of scope.
- The file provider matches the application integration guide.

### 3.5 TLS

Canonical resolver:

- `cloudflare` using ACME DNS-01.

Optional fallback resolver:

- `letsencrypt-http` using ACME HTTP-01.

The fallback exists only for environments where Cloudflare DNS API access is unavailable. For the planned stack, use `cloudflare`.

### 3.6 Dashboard

- Dashboard is optional.
- If enabled, bind only to `127.0.0.1:8080`.
- Do not expose the dashboard publicly.
- Access it using SSH local port forwarding.

### 3.7 Metrics

- Enable Prometheus metrics only on `127.0.0.1:8082`.
- Do not expose port `8082` publicly.
- If `https://metrics.<domain>` is required, route it through Traefik only behind VPN and authentication.

## 4. Preinstallation Checks

Run as root or a sudo-enabled administrative user.

### 4.1 Verify OS and architecture

```bash
source /etc/os-release
printf 'OS: %s\nVersion: %s\n' "$NAME" "$VERSION"
uname -m
```

Expected:

- `aarch64`.
- Oracle Linux Server 9.8.

### 4.2 Verify `/data` availability

```bash
mountpoint -q /data && echo "/data mounted" || echo "/data not mounted"
```

`/data` must be mounted before Traefik state or logs are created.

### 4.3 Check Podman presence

This guide does not require Podman for Traefik.

```bash
if command -v podman >/dev/null 2>&1; then
  podman --version
else
  echo "Podman not installed"
fi
```

Recommendation:

- If Podman is installed, leave it installed for application workloads.
- Do not use it for Traefik unless containerization is mandatory.
- Do not install Podman solely for Traefik.

### 4.4 Check reserved ports

```bash
sudo ss -ltnp | grep -E ':80|:443|:8080|:8082' || true
```

Ports used by Traefik in this guide:

| Port | Purpose                                    |
| ---: | ------------------------------------------ |
|   80 | HTTP, redirected to HTTPS                  |
|  443 | HTTPS                                      |
| 8080 | Traefik dashboard/API, localhost only      |
| 8082 | Traefik Prometheus metrics, localhost only |

Do not expose ports `8080` or `8082` publicly.

## 5. Install Required Packages

```bash
sudo dnf install -y curl tar jq policycoreutils-python-utils firewalld audit
```

Packages:

- `curl`: downloads Traefik releases.
- `tar`: extracts release archives.
- `jq`: parses GitHub release metadata.
- `policycoreutils-python-utils`: provides `semanage`.
- `firewalld`: host firewall.
- `audit`: audit rule management.

## 6. Create Traefik User, Directories, and Secret File

### 6.1 Create service user

```bash
sudo useradd \
  --system \
  --home-dir /data/traefik \
  --shell /sbin/nologin \
  --comment "Traefik reverse proxy" \
  traefik
```

Security properties:

- System account.
- No interactive shell.
- No sudo access.
- Dedicated state path under `/data/traefik`.

### 6.2 Create directories

```bash
sudo install -d -m 0755 /etc/traefik/config
sudo install -d -m 0755 /opt/traefik/bin
sudo install -d -m 0755 /opt/traefik/releases
sudo install -d -m 0750 -o traefik -g traefik /data/traefik
sudo install -d -m 0750 -o traefik -g traefik /data/logs/traefik
sudo install -d -m 0700 -o root -g root /data/backups/traefik
```

Purpose:

- `/etc/traefik`: static and dynamic Traefik configuration.
- `/etc/traefik/config`: hot-reloaded dynamic configuration.
- `/opt/traefik`: read-only Traefik binaries.
- `/data/traefik`: persistent ACME state and secret environment file.
- `/data/logs/traefik`: persistent Traefik logs.
- `/data/backups/traefik`: local backup directory.

### 6.3 Create ACME state file

```bash
sudo install -m 0600 -o traefik -g traefik /dev/null /data/traefik/acme.json
```

This file stores ACME account and certificate state. Protect it strictly.

### 6.4 Create secret environment file

```bash
sudo install -m 0600 -o root -g root /dev/null /data/traefik/traefik.env
```

The Cloudflare API token must be written here by OCI Vault during provisioning.

Example content:

```text
CF_API_TOKEN=replace-with-token-from-oci-vault
```

Requirements:

- File location: `/data/traefik/traefik.env`.
- Owner: `root:root`.
- Mode: `0600`.
- Do not place the token in `traefik.yml`.
- Do not commit the token to version control.
- Do not write secrets outside `/data/`.

The Cloudflare token must have:

- `Zone → DNS → Edit` permission.
- Scope covering every domain for which Traefik issues certificates.

Validate the exact environment variable name required by the deployed Traefik version. For current Traefik v3 deployments, `CF_API_TOKEN` is commonly used.

## 7. Traefik Static Configuration

Create `/etc/traefik/traefik.yml`.

```bash
sudo tee /etc/traefik/traefik.yml > /dev/null <<'EOF'
global:
  checkNewVersion: false
  sendAnonymousUsage: false

api:
  dashboard: true
  insecure: true

ping:
  entryPoint: traefik

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true

  websecure:
    address: ":443"
    http:
      tls:
        certResolver: cloudflare

  traefik:
    address: "127.0.0.1:8080"

  metrics:
    address: "127.0.0.1:8082"

providers:
  file:
    directory: /etc/traefik/config
    watch: true

certificatesResolvers:
  cloudflare:
    acme:
      email: security@example.com
      storage: /data/traefik/acme.json
      dnsChallenge:
        provider: cloudflare

  letsencrypt-http:
    acme:
      email: security@example.com
      storage: /data/traefik/acme.json
      httpChallenge:
        entryPoint: web

metrics:
  prometheus:
    entryPoint: metrics
    addRoutersLabels: true
    addServicesLabels: true

log:
  level: WARN
  filePath: /data/logs/traefik/traefik.log

accessLog:
  filePath: /data/logs/traefik/access.log
  format: json
  bufferingSize: 100
  fields:
    headers:
      defaultMode: redact
EOF
```

Replace `security@example.com` with a valid operational email address.

Set ownership and permissions:

```bash
sudo chown root:root /etc/traefik/traefik.yml
sudo chmod 0644 /etc/traefik/traefik.yml
```

Configuration notes:

- HTTP is redirected to HTTPS.
- The default certificate resolver is `cloudflare`.
- The Cloudflare resolver uses DNS-01.
- The fallback resolver `letsencrypt-http` exists but is not the canonical stack resolver.
- The dashboard is bound to `127.0.0.1:8080`.
- Prometheus metrics are bound to `127.0.0.1:8082`.
- Access logs are JSON-formatted and header values are redacted.
- Dynamic configuration is read from `/etc/traefik/config`.
- No Podman socket is used.

## 8. Shared Dynamic Infrastructure Configuration

Create `/etc/traefik/config/00-infra.yaml`.

```bash
sudo tee /etc/traefik/config/00-infra.yaml > /dev/null <<'EOF'
http:
  middlewares:
    global-security-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: false
        forceSTSHeader: true
        frameDeny: true
        contentTypeNosniff: true
        referrerPolicy: "strict-origin-when-cross-origin"
        permissionsPolicy: "camera=(), microphone=(), geolocation=()"

    # admin-chain and wg-allowlist are stack-provided middlewares.
    # They depend on Authelia and WireGuard and must be created by the
    # stack infrastructure configuration before application routers
    # reference them.
EOF
```

Set ownership and permissions:

```bash
sudo chown root:root /etc/traefik/config/00-infra.yaml
sudo chmod 0644 /etc/traefik/config/00-infra.yaml
```

Application route configs should reference `global-security-headers` as required by the application integration guide.

Do not define a global CSP here. CSP is application-specific.

## 9. Metrics Exposure

This guide enables metrics locally only:

```text
http://127.0.0.1:8082/metrics
```

Do not expose port `8082` in the OCI Security List.

If the stack requires `https://metrics.<domain>`, create a protected Traefik route only after the stack authentication middleware exists.

Example, not enabled by default:

```yaml
http:
  routers:
    traefik-metrics:
      rule: "Host(`metrics.example.com`)"
      entryPoints:
        - websecure
      service: prometheus@internal
      middlewares:
        - admin-chain
      tls:
        certResolver: cloudflare
```

Security requirement:

- Do not expose metrics publicly.
- Require VPN and authentication.
- Validate the internal Prometheus service name against the deployed Traefik version.

## 10. Traefik Binary Installation and Update Script

Create `/usr/local/sbin/traefik-update`.

```bash
sudo tee /usr/local/sbin/traefik-update > /dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO="traefik/traefik"
ARCH="arm64"
INSTALL_ROOT="/opt/traefik"
BIN_LINK="${INSTALL_ROOT}/bin/traefik"
RELEASES_DIR="${INSTALL_ROOT}/releases"
LOG_FILE="/data/logs/traefik/update.log"

if ! mountpoint -q /data; then
  echo "/data is not mounted" >&2
  exit 1
fi

install -d -m 0750 -o traefik -g traefik /data/logs/traefik
touch "$LOG_FILE"

log() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG_FILE"
}

if [[ $EUID -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if [[ "$(uname -m)" != "aarch64" ]]; then
  log "Unsupported architecture: $(uname -m)"
  exit 1
fi

if [[ $# -ge 1 && -n "$1" ]]; then
  TAG="$1"
else
  TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | jq -r '.tag_name')
fi

if [[ "$TAG" != v* ]]; then
  TAG="v${TAG}"
fi

CURRENT=""
if [[ -x "$BIN_LINK" ]]; then
  CURRENT=$("$BIN_LINK" version 2>/dev/null | awk '/^Version:/ {print $2}' || true)
fi

if [[ "$CURRENT" == "$TAG" ]]; then
  log "Already at target version ${TAG}"
  exit 0
fi

URL="https://github.com/traefik/traefik/releases/download/${TAG}/traefik_${TAG}_linux_${ARCH}.tar.gz"
SUMS="https://github.com/traefik/traefik/releases/download/${TAG}/traefik_${TAG}_checksums.txt"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log "Downloading Traefik ${TAG}"

curl -fsSL "$SUMS" -o "${TMP}/checksums.txt"
curl -fsSL "$URL" -o "${TMP}/traefik.tar.gz"

EXPECTED=$(grep "traefik_${TAG}_linux_${ARCH}.tar.gz" "${TMP}/checksums.txt" | awk '{print $NF}' | head -n1)
ACTUAL=$(sha256sum "${TMP}/traefik.tar.gz" | awk '{print $1}')

if [[ -z "$EXPECTED" ]]; then
  log "Checksum entry not found for ${TAG}"
  exit 1
fi

if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  log "Checksum mismatch for ${TAG}"
  exit 1
fi

tar -xzf "${TMP}/traefik.tar.gz" -C "${TMP}"

install -d -m 0755 "${RELEASES_DIR}/${TAG}"
install -m 0755 "${TMP}/traefik" "${RELEASES_DIR}/${TAG}/traefik"

ln -sfn "${RELEASES_DIR}/${TAG}/traefik" "$BIN_LINK"
restorecon -R "${INSTALL_ROOT}" >/dev/null 2>&1 || true

if systemctl is-active --quiet traefik; then
  systemctl restart traefik
  sleep 2

  if ! systemctl is-active --quiet traefik; then
    log "Traefik failed after update to ${TAG}"

    if [[ -n "$CURRENT" && -x "${RELEASES_DIR}/${CURRENT}/traefik" ]]; then
      log "Rolling back to ${CURRENT}"
      ln -sfn "${RELEASES_DIR}/${CURRENT}/traefik" "$BIN_LINK"
      systemctl restart traefik
    fi

    exit 1
  fi
fi

log "Traefik updated to ${TAG}"
EOF

sudo chmod 0755 /usr/local/sbin/traefik-update
sudo chown root:root /usr/local/sbin/traefik-update
```

Run the first installation:

```bash
sudo /usr/local/sbin/traefik-update
```

Verify:

```bash
/opt/traefik/bin/traefik version
```

## 11. Systemd Service

Create `/etc/systemd/system/traefik.service`.

```bash
sudo tee /etc/systemd/system/traefik.service > /dev/null <<'EOF'
[Unit]
Description=Traefik reverse proxy
After=network-online.target local-fs.target
Wants=network-online.target
Requires=local-fs.target

[Service]
Type=simple
User=traefik
Group=traefik
EnvironmentFile=/data/traefik/traefik.env
ExecStart=/opt/traefik/bin/traefik --configfile=/etc/traefik/traefik.yml
Restart=on-failure
RestartSec=5

NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native

ConfigurationDirectory=traefik
ReadWritePaths=/data/traefik /data/logs/traefik

LimitNOFILE=65536
TasksMax=1024
EOF
```

Reload systemd:

```bash
sudo systemctl daemon-reload
```

Enable and start Traefik:

```bash
sudo systemctl enable --now traefik.service
```

Verify:

```bash
sudo systemctl status traefik.service
```

## 12. SELinux

Keep SELinux in enforcing mode.

```bash
getenforce
```

Expected:

```text
Enforcing
```

Apply contexts:

```bash
sudo semanage fcontext -a -t bin_t "/opt/traefik(/.*)?" 2>/dev/null || true
sudo semanage fcontext -a -t var_log_t "/data/logs/traefik(/.*)?" 2>/dev/null || true
sudo semanage fcontext -a -t cert_t "/data/traefik(/.*)?" 2>/dev/null || true

sudo restorecon -Rv /opt/traefik
sudo restorecon -Rv /etc/traefik
sudo restorecon -Rv /data/traefik
sudo restorecon -Rv /data/logs/traefik
```

If SELinux denials occur:

```bash
sudo ausearch -m avc -ts recent
```

Do not disable SELinux to resolve denials unless no safer alternative exists.

## 13. Host Firewall and OCI Network Rules

Enable HTTP and HTTPS only.

```bash
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

Verify:

```bash
sudo firewall-cmd --list-all
```

OCI Security List or Network Security Group must allow inbound TCP:

- 80
- 443

Do not allow inbound public access to:

- 8080
- 8082

## 14. Verification

### 14.1 Service status

```bash
sudo systemctl status traefik
```

### 14.2 Listening ports

```bash
sudo ss -ltnp | grep -E ':80|:443|:8080|:8082'
```

Expected:

- `:80`
- `:443`
- `127.0.0.1:8080`
- `127.0.0.1:8082`

### 14.3 Ping endpoint

```bash
curl -fsS http://127.0.0.1:8080/ping
```

### 14.4 Metrics endpoint

```bash
curl -fsS http://127.0.0.1:8082/metrics
```

### 14.5 Logs

```bash
sudo journalctl -u traefik.service -n 100 --no-pager
sudo tail -n 50 /data/logs/traefik/traefik.log
```

### 14.6 HTTP redirect

If a domain points to the instance:

```bash
curl -I http://example.com
```

Expected:

- HTTP redirect to HTTPS.

### 14.7 ACME status

```bash
sudo grep -i acme /data/logs/traefik/traefik.log
```

For Cloudflare DNS-01:

- Ensure the Cloudflare token is present in `/data/traefik/traefik.env`.
- Ensure DNS records exist.
- Ensure DNS records are set to DNS Only, grey cloud, unless another TLS design is explicitly approved.

## 15. Dashboard Access

The dashboard is bound to localhost only.

Access it from an administrative workstation using SSH local port forwarding:

```bash
ssh -L 8080:127.0.0.1:8080 admin-user@instance-ip
```

Then open:

```text
http://127.0.0.1:8080/dashboard/
```

Do not expose the dashboard publicly.

## 16. Application Integration Contract

This section defines the Traefik-side expectations for application integration. It does not configure applications.

### 16.1 Route file location

Application route files must be placed in:

```text
/etc/traefik/config/<app-name>.yaml
```

Traefik hot-reloads this directory.

### 16.2 Backend convention

Application backends must be reachable on loopback:

```text
http://127.0.0.1:<host-port>
```

Applications must bind only to `127.0.0.1`.

Do not route Traefik to public application ports.

### 16.3 TLS

Applications must not manage TLS certificates.

Application route configs should use:

```yaml
tls:
  certResolver: cloudflare
```

Traffic between Traefik and the application is plain HTTP over loopback.

### 16.4 Middlewares

`global-security-headers` is provided by this guide.

Application route configs should reference it where required.

`admin-chain` and `wg-allowlist` must be provided by the stack infrastructure configuration before application routes reference them.

## 17. Ongoing Maintenance

### 17.1 Automated Traefik updates

Create `/etc/systemd/system/traefik-update.service`.

```bash
sudo tee /etc/systemd/system/traefik-update.service > /dev/null <<'EOF'
[Unit]
Description=Update Traefik binary

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/traefik-update
EOF
```

Create `/etc/systemd/system/traefik-update.timer`.

```bash
sudo tee /etc/systemd/system/traefik-update.timer > /dev/null <<'EOF'
[Unit]
Description=Daily Traefik update check

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=45m

[Install]
WantedBy=timers.target
EOF
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now traefik-update.timer
```

Check:

```bash
systemctl list-timers traefik-update.timer
```

To pin a version:

```bash
sudo /usr/local/sbin/traefik-update v3.2.5
```

Replace `v3.2.5` with the required version.

### 17.2 Manual rollback

List installed versions:

```bash
ls -l /opt/traefik/releases
```

Roll back:

```bash
sudo ln -sfn /opt/traefik/releases/vOLD/traefik /opt/traefik/bin/traefik
sudo systemctl restart traefik
sudo systemctl status traefik
```

Replace `vOLD` with the previous release directory.

### 17.3 Oracle Linux security updates

```bash
sudo dnf install -y dnf-automatic
sudo sed -i 's/^apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
sudo systemctl enable --now dnf-automatic-install.timer
```

Verify:

```bash
systemctl list-timers dnf-automatic-install.timer
```

### 17.4 Log rotation

Create `/etc/logrotate.d/traefik`.

```bash
sudo tee /etc/logrotate.d/traefik > /dev/null <<'EOF'
/data/logs/traefik/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
```

Test:

```bash
sudo logrotate -d /etc/logrotate.d/traefik
```

### 17.5 Configuration and ACME backup

Restic is the primary backup mechanism for `/data/`. This local backup script is a secondary operational backup for root-filesystem Traefik configuration and critical ACME state.

Create `/usr/local/sbin/traefik-backup`.

```bash
sudo tee /usr/local/sbin/traefik-backup > /dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="/data/backups/traefik"
STAMP="$(date +%F-%H%M%S)"

if ! mountpoint -q /data; then
  echo "/data is not mounted" >&2
  exit 1
fi

install -d -m 0700 "$BACKUP_ROOT"

tar --exclude='data/traefik/traefik.env' \
    -czf "${BACKUP_ROOT}/traefik-${STAMP}.tar.gz" \
    /etc/traefik \
    /data/traefik

find "$BACKUP_ROOT" -name 'traefik-*.tar.gz' -mtime +30 -delete
EOF

sudo chmod 0755 /usr/local/sbin/traefik-backup
sudo chown root:root /usr/local/sbin/traefik-backup
```

Create `/etc/systemd/system/traefik-backup.service`.

```bash
sudo tee /etc/systemd/system/traefik-backup.service > /dev/null <<'EOF'
[Unit]
Description=Backup Traefik configuration and ACME state

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/traefik-backup
EOF
```

Create `/etc/systemd/system/traefik-backup.timer`.

```bash
sudo tee /etc/systemd/system/traefik-backup.timer > /dev/null <<'EOF'
[Unit]
Description=Daily Traefik backup

[Timer]
OnCalendar=*-*-* 04:05:00
Persistent=true
RandomizedDelaySec=20m

[Install]
WantedBy=timers.target
EOF
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now traefik-backup.timer
```

Verify:

```bash
systemctl list-timers traefik-backup.timer
```

Secret handling:

- The local backup excludes `/data/traefik/traefik.env`.
- The Cloudflare token must be restored from OCI Vault.
- Restic may still back up `/data/traefik/traefik.env` as part of `/data/`. Ensure Restic storage is protected.

### 17.6 Certificate maintenance

Traefik handles ACME renewal automatically.

Operational checks:

```bash
sudo systemctl status traefik
sudo grep -i acme /data/logs/traefik/traefik.log
```

If ACME state becomes corrupted:

```bash
sudo systemctl stop traefik
sudo install -m 0600 -o traefik -g traefik /path/to/restored/acme.json /data/traefik/acme.json
sudo systemctl start traefik
```

If the Cloudflare token is lost:

- Retrieve it from OCI Vault.
- Write it to `/data/traefik/traefik.env`.
- Ensure permissions remain `0600` and owner remains `root:root`.
- Restart Traefik.

## 18. Audit Rules

Create `/etc/audit/rules.d/traefik.rules`.

```bash
sudo tee /etc/audit/rules.d/traefik.rules > /dev/null <<'EOF'
-w /etc/traefik -p wa -k traefik_config
-w /data/traefik -p wa -k traefik_state
-w /opt/traefik -p wa -k traefik_binary
-w /etc/systemd/system/traefik.service -p wa -k traefik_unit
-w /usr/local/sbin/traefik-update -p wa -k traefik_update
-w /usr/local/sbin/traefik-backup -p wa -k traefik_backup
EOF
```

Load rules:

```bash
sudo augenrules --load
```

Query recent events:

```bash
sudo ausearch -k traefik_config -ts today
sudo ausearch -k traefik_state -ts today
sudo ausearch -k traefik_binary -ts today
sudo ausearch -k traefik_update -ts today
```

## 19. VM Replacement Requirements

The root filesystem is ephemeral. On VM replacement, the following must be recreated by cloud-init or stack provisioning:

- Package installation.
- `traefik` user.
- `/etc/traefik/traefik.yml`.
- `/etc/traefik/config/00-infra.yaml`.
- `/usr/local/sbin/traefik-update`.
- `/usr/local/sbin/traefik-backup`.
- `/etc/systemd/system/traefik.service`.
- `/etc/systemd/system/traefik-update.service`.
- `/etc/systemd/system/traefik-update.timer`.
- `/etc/systemd/system/traefik-backup.service`.
- `/etc/systemd/system/traefik-backup.timer`.
- `/etc/logrotate.d/traefik`.
- `/etc/audit/rules.d/traefik.rules`.
- SELinux file contexts.
- Firewall rules.

Persistent items under `/data/` survive replacement:

- `/data/traefik/acme.json`.
- `/data/traefik/traefik.env`.
- `/data/logs/traefik/`.
- `/data/backups/traefik/`.

Traefik must start only after `/data/` is mounted. The systemd unit already uses:

```ini
Requires=local-fs.target
After=local-fs.target
```

If `/data` is represented by a more specific mount unit, use that unit in `After=` and `Requires=`.

## 20. Security Maintenance Checklist

Run these checks periodically.

```bash
systemctl status traefik
getenforce
sudo firewall-cmd --list-all
sudo ss -ltnp | grep -E ':80|:443|:8080|:8082'
ls -l /opt/traefik/bin/traefik
ls -ld /data/traefik /data/logs/traefik /etc/traefik
ls -l /data/traefik/acme.json
ls -l /data/traefik/traefik.env
id traefik
sudo last -n 20
sudo ausearch -k traefik_config -ts today
sudo ausearch -k traefik_state -ts today
```

Expected security posture:

- Traefik runs as `traefik`, not root and not an SSH user.
- `/data/traefik/acme.json` is mode `0600`.
- `/data/traefik/traefik.env` is mode `0600` and owned by `root:root`.
- `/opt/traefik` is owned by root.
- `/etc/traefik` is owned by root.
- Dashboard is only on `127.0.0.1:8080`.
- Metrics are only on `127.0.0.1:8082`.
- No Podman socket is mounted into Traefik.
- SELinux remains enforcing.
- Only ports 80, 443, and SSH are exposed as intended.
- Cloudflare token is not present in `traefik.yml`.
- Application route files are root-owned and generated by trusted deployment manifests.

## 21. Operational Commands

Start:

```bash
sudo systemctl start traefik
```

Stop:

```bash
sudo systemctl stop traefik
```

Restart:

```bash
sudo systemctl restart traefik
```

Logs:

```bash
sudo journalctl -u traefik -f
sudo tail -f /data/logs/traefik/traefik.log
sudo tail -f /data/logs/traefik/access.log
```

Update immediately:

```bash
sudo /usr/local/sbin/traefik-update
```

Backup immediately:

```bash
sudo /usr/local/sbin/traefik-backup
```

Reload audit rules:

```bash
sudo augenrules --load
```
