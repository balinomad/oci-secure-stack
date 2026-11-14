---
name: "Traefik Reference"
description: |
  Exact Traefik static and dynamic configuration, systemd unit, binary update, backup, logging, audit, and SELinux settings for the host.
status: draft
version: 1.2
updated: 2026-11-14
---

# Traefik Reference

This page documents this stack's Traefik installation, configuration, and maintenance. It is not an upstream Traefik manual.

## 1. Traefik static configuration

`/etc/traefik/traefik.yaml`:

```yaml
global:
  checkNewVersion: false
  sendAnonymousUsage: false

api:
  dashboard: true
  insecure: false

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
      storage: /etc/traefik/letsencrypt/acme.json
      dnsChallenge:
        provider: cloudflare

  letsencrypt-http:
    acme:
      email: security@example.com
      storage: /etc/traefik/letsencrypt/acme.json
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
```

Replace `security@example.com` with the operational email. File ownership is `root:root`, mode `0644`.

The dashboard and API are attached to the `traefik` entrypoint on `127.0.0.1:8080` through a dynamic router with service `api@internal`. Metrics are bound to `127.0.0.1:8082`. No Podman socket is used.

## 2. Shared dynamic configuration

`/etc/traefik/config/00-infra.yaml`:

```yaml
http:
  middlewares:
    # IP allowlist: only WireGuard VPN subnet permitted.
    wg-allowlist:
      ipAllowList:
        sourceRange:
          - "10.0.0.0/24"

    # Authelia forwardAuth: delegates authentication to Authelia.
    authelia-forward-auth:
      forwardAuth:
        address: "http://127.0.0.1:9091/api/authz/forward-auth"
        trustForwardHeader: true
        authResponseHeaders:
          - "Remote-User"
          - "Remote-Groups"
          - "Remote-Name"
          - "Remote-Email"

    # Admin middleware chain: IP check first, then Authelia.
    admin-chain:
      chain:
        middlewares:
          - wg-allowlist
          - authelia-forward-auth

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

tls:
  options:
    default:
      minVersion: VersionTLS12
      sniStrict: true
```

Do not define a global CSP here. CSP is application-specific.

The current implementation defines `global-security-headers` but does not attach it to the routers. Finding F7 records that defect.

The Authelia portal is reachable only from the VPN subnet and does not use `forwardAuth`, which avoids a circular redirect:

```yaml
http:
  routers:
    authelia:
      rule: "Host(`auth.${DOMAIN}`)"
      entryPoints:
        - websecure
      service: authelia-svc
      middlewares:
        - wg-allowlist
        - global-security-headers
      tls:
        certResolver: cloudflare

  services:
    authelia-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:9091"
```

Cockpit and wg-easy use the full admin chain:

```yaml
http:
  routers:
    cockpit:
      rule: "Host(`cockpit.${DOMAIN}`)"
      entryPoints:
        - websecure
      service: cockpit-svc
      middlewares:
        - admin-chain
        - global-security-headers
      tls:
        certResolver: cloudflare

    wg-easy:
      rule: "Host(`wg.${DOMAIN}`)"
      entryPoints:
        - websecure
      service: wg-easy-svc
      middlewares:
        - admin-chain
        - global-security-headers
      tls:
        certResolver: cloudflare

  services:
    cockpit-svc:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://127.0.0.1:9090"

    wg-easy-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:51821"
```

`passHostHeader: true` is required for Cockpit WebSocket support. Cockpit also requires `/etc/cockpit/cockpit.conf` with an `Origins` entry for `https://cockpit.${DOMAIN}` and `ProtocolHeader = X-Forwarded-Proto`. The host must bind Cockpit to `127.0.0.1:9090` and block direct access to port 9090.

The Traefik dashboard and metrics are not routed through public hostnames. The dashboard uses the loopback `traefik` entrypoint on `127.0.0.1:8080`, and metrics use `127.0.0.1:8082`. Both are reached through an SSH tunnel. Findings F6 and F8 track deployment verification.

## 3. Traefik systemd unit

`/etc/systemd/system/traefik.service`:

```ini
[Unit]
Description=Traefik reverse proxy
After=network-online.target local-fs.target
Wants=network-online.target
Requires=local-fs.target

[Service]
Type=simple
User=traefik
Group=traefik
EnvironmentFile=/etc/traefik/env
ExecStart=/opt/traefik/bin/traefik --configFile=/etc/traefik/traefik.yaml
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
ReadWritePaths=/data/traefik/letsencrypt /data/logs/traefik

LimitNOFILE=65536
TasksMax=1024
```

## 4. Traefik user and directories

```bash
sudo useradd \
  --system \
  --home-dir /data/traefik \
  --shell /sbin/nologin \
  --comment "Traefik reverse proxy" \
  traefik

sudo install -d -m 0755 /etc/traefik/config
sudo install -d -m 0755 /opt/traefik/bin
sudo install -d -m 0755 /opt/traefik/releases
sudo install -d -m 0750 -o traefik -g traefik /data/traefik
sudo install -d -m 0700 -o traefik -g traefik /data/traefik/letsencrypt
sudo install -d -m 0750 -o traefik -g traefik /data/logs/traefik
sudo install -d -m 0700 -o root -g root /data/backups/traefik
```

ACME state and secret environment:

```bash
sudo install -m 0600 -o traefik -g traefik /dev/null /data/traefik/letsencrypt/acme.json
sudo install -m 0600 -o traefik -g traefik /dev/null /etc/traefik/env
```

`/etc/traefik/env` contains:

```text
CF_DNS_API_TOKEN=replace-with-token-from-oci-vault
```

The file must be owned by `traefik:traefik` and mode `0600`. The token must not appear in `traefik.yaml`.

## 5. Traefik binary update script

`/usr/local/sbin/traefik-update`:

```bash
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
```

The script assumes ARM64. Change `ARCH` for AMD64. It verifies the release checksum and rolls back when the new binary fails to start.

Update units:

```ini
# /etc/systemd/system/traefik-update.service
[Unit]
Description=Update Traefik binary

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/traefik-update
```

```ini
# /etc/systemd/system/traefik-update.timer
[Unit]
Description=Daily Traefik update check

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=45m

[Install]
WantedBy=timers.target
```

## 6. Traefik local backup

`/usr/local/sbin/traefik-backup`:

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="/data/backups/traefik"
STAMP="$(date +%F-%H%M%S)"

if ! mountpoint -q /data; then
  echo "/data is not mounted" >&2
  exit 1
fi

install -d -m 0700 "$BACKUP_ROOT"

tar --exclude='etc/traefik/env' \
    -czf "${BACKUP_ROOT}/traefik-${STAMP}.tar.gz" \
    /etc/traefik \
    /data/traefik

find "$BACKUP_ROOT" -name 'traefik-*.tar.gz' -mtime +30 -delete
```

Units:

```ini
# /etc/systemd/system/traefik-backup.service
[Unit]
Description=Backup Traefik configuration and ACME state

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/traefik-backup
```

```ini
# /etc/systemd/system/traefik-backup.timer
[Unit]
Description=Daily Traefik backup

[Timer]
OnCalendar=*-*-* 04:05:00
Persistent=true
RandomizedDelaySec=20m

[Install]
WantedBy=timers.target
```

## 7. Logrotate and audit rules

`/etc/logrotate.d/traefik`:

```text
/data/logs/traefik/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
```

`/etc/audit/rules.d/traefik.rules`:

```text
-w /etc/traefik -p wa -k traefik_config
-w /data/traefik -p wa -k traefik_state
-w /opt/traefik -p wa -k traefik_binary
-w /etc/systemd/system/traefik.service -p wa -k traefik_unit
-w /usr/local/sbin/traefik-update -p wa -k traefik_update
-w /usr/local/sbin/traefik-backup -p wa -k traefik_backup
```

Load with `sudo augenrules --load`.

## 8. SELinux contexts

```bash
sudo semanage fcontext -a -t bin_t "/opt/traefik(/.*)?" 2>/dev/null || true
sudo semanage fcontext -a -t var_log_t "/data/logs/traefik(/.*)?" 2>/dev/null || true
sudo semanage fcontext -a -t cert_t "/data/traefik(/.*)?" 2>/dev/null || true

sudo restorecon -Rv /opt/traefik
sudo restorecon -Rv /etc/traefik
sudo restorecon -Rv /data/traefik
sudo restorecon -Rv /data/logs/traefik
```

## Related documents

- Design: `docs/architecture.md`
- Operations: `docs/guides/operations.md`
- Infrastructure reference: `docs/reference/infrastructure.md`
- Application manifest reference: `docs/reference/application-manifest.md`
