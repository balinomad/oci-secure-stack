# Application Integration Guidelines

## OCI Oracle Linux 9 — Secure Admin Stack

> **This document is for application developers and architects** planning to deploy an application into the secure admin stack described in `stack-guide.md`. It defines the integration points between the stack's existing infrastructure and hosted applications, clarifies which responsibilities belong to the stack versus the application, and provides concrete guidance for each integration layer.

## Table of Contents

1. [Scope and Philosophy](#1-scope-and-philosophy)
2. [Responsibility Boundaries](#2-responsibility-boundaries)
3. [Container Runtime — Podman Quadlet](#3-container-runtime--podman-quadlet)
4. [Building Container Images](#4-building-container-images)
5. [Reverse Proxy — Traefik](#5-reverse-proxy--traefik)
6. [Security Headers and CSP](#6-security-headers-and-csp)
7. [Authentication and Authorization](#7-authentication-and-authorization)
8. [Persistent Storage — Block Volume](#8-persistent-storage--block-volume)
9. [Secrets Management — OCI Vault](#9-secrets-management--oci-vault)
10. [Logging](#10-logging)
11. [Backup](#11-backup)
12. [TLS and Network Binding](#12-tls-and-network-binding)
13. [Monitoring](#13-monitoring)
14. [SELinux Considerations](#14-selinux-considerations)
15. [Automated Deployment Across VM Replacement](#15-automated-deployment-across-vm-replacement)
16. [Deployment Workflow](#16-deployment-workflow)
17. [Integration Checklist](#17-integration-checklist)

## 1. Scope and Philosophy

The stack provides a set of shared infrastructure services: routing, TLS termination, authentication, persistent storage, backup, and service management. Applications hosted on the stack should integrate with these services rather than re-implement them.

The guiding principle is **separation of concerns**:

- The stack owns the infrastructure layer
- The application owns its business logic, data model, and user-facing behaviour

Some integration points are **mandatory** — they are required for the application to function correctly within the stack and cannot be bypassed. Others are **optional** — the stack offers a capability but the application may have a valid reason to handle it differently.

| Layer                                         | Mandatory      | Optional |
| --------------------------------------------- | -------------- | -------- |
| Podman Quadlet for container lifecycle        | ✅             | —        |
| Traefik for HTTP routing and TLS              | ✅             | —        |
| `127.0.0.1` network binding                   | ✅             | —        |
| `/data/containers/<app>/` for persistent data | ✅             | —        |
| Restic backup via `/data/`                    | ✅ (automatic) | —        |
| Authelia for authentication                   | —              | ✅       |
| OCI Vault for secrets                         | —              | ✅       |
| Stack logging conventions                     | —              | ✅       |
| Prometheus metrics exposure                   | —              | ✅       |

## 2. Responsibility Boundaries

| Concern                       | Stack Owns                                        | Application Owns                                    |
| ----------------------------- | ------------------------------------------------- | --------------------------------------------------- |
| TLS certificates              | Issuance, renewal, termination                    | Nothing — do not touch                              |
| HTTP routing                  | Domain assignment, middleware chains              | Route config file in `/etc/traefik/config/`         |
| Global security headers       | HSTS, `X-Frame-Options`, `X-Content-Type-Options` | Content-Security-Policy (see Section 6)             |
| Authentication infrastructure | Authelia SSO                                      | Auth integration choice (see Section 7)             |
| Authorization                 | Coarse group-based via Authelia                   | Fine-grained RBAC within the application            |
| Container lifecycle           | systemd via Quadlet                               | Container image, ports, env vars, health            |
| Persistent storage            | Block volume mount at `/data/`                    | Directory structure under `/data/containers/<app>/` |
| Backup                        | Restic covers all of `/data/` automatically       | Storing data under `/data/containers/<app>/`        |
| Secret storage                | OCI Vault infrastructure                          | Creating and referencing app-specific secrets       |
| Logging infrastructure        | Journal, Traefik access logs                      | Application log output, format, and rotation        |
| Monitoring infrastructure     | PCP, Prometheus endpoint                          | Exposing `/metrics` endpoint (optional)             |
| OS security                   | SELinux, auditd, firewall                         | `:Z` volume flag, no privileged containers          |
| Networking                    | Firewall, public port exposure                    | Internal binding to `127.0.0.1` only                |
| VM lifecycle                  | Cloud-init, block volume                          | Nothing — the VM is ephemeral                       |

## 3. Container Runtime — Podman Quadlet

All application containers are managed using **Podman Quadlet** — the native systemd-integrated container management system. `podman-compose`, `docker-compose`, and manual `podman run` commands are not used in this stack.

### 3.1 Quadlet Unit File

Create `/etc/containers/systemd/<app-name>.container`:

```ini
[Unit]
Description=<App Name>
After=local-fs.target network-online.target
Requires=local-fs.target

[Container]
Image=<image>:<tag>
PublishPort=127.0.0.1:<host-port>:<container-port>
Volume=/data/containers/<app-name>/data:<container-data-path>:Z
Volume=/data/containers/<app-name>/logs:<container-log-path>:Z
EnvironmentFile=/data/containers/<app-name>/env

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
```

`Requires=local-fs.target` is mandatory — it ensures the block volume is mounted before the container starts on every boot.

### 3.2 Key Rules

- Never use `--privileged` — request only the capabilities the container actually needs via `AddCapability=`
- Never bind to `0.0.0.0` — all ports must be bound to `127.0.0.1`
- Pin image versions — use a specific tag (e.g. `myapp:2.1.0`), never `:latest` in production
- Use `EnvironmentFile=` — never embed secrets in the unit file or image

### 3.3 Activation

```bash
# Generate or place the .container file, then:
sudo systemctl daemon-reload
sudo systemctl enable --now <app-name>

# Verify
sudo systemctl status <app-name>
sudo journalctl -u <app-name> -n 50
```

## 4. Building Container Images

Podman uses `Containerfile` as the canonical filename (the Red Hat/OCI ecosystem name), though `Dockerfile` is also accepted. The syntax is identical to Dockerfile — all existing Docker build knowledge applies directly.

### 4.1 Multi-Stage Builds (Required for Compiled Languages)

For compiled applications (Go, Rust, C, C++, Java), the build toolchain must never be included in the production image. Use a multi-stage `Containerfile` that separates the build environment from the runtime image.

**Go example (produces a minimal `scratch`-based image):**

```dockerfile
# Stage 1: Build
# Use the official Go toolchain image as the builder
FROM docker.io/library/golang:1.22 AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# CGO_ENABLED=0 produces a fully static binary with no shared library dependencies.
# -ldflags="-w -s" strips debug info and symbol tables, reducing binary size.
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-w -s" \
    -o /app/server .

# Stage 2: Minimal runtime image
# scratch contains nothing — no shell, no libraries, no OS utilities.
# This is the smallest and most secure runtime base for static Go binaries.
FROM scratch

# Copy TLS root certificates so the binary can make HTTPS calls
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy only the compiled binary
COPY --from=builder /app/server /server

EXPOSE 8080
ENTRYPOINT ["/server"]
```

The builder stage produces a binary; the runtime image contains only that binary. Build tools, source code, and intermediate files are discarded. The resulting image is typically 10–20 MB versus 1+ GB for a single-stage build, and has zero OS-level vulnerabilities in the base layer.

**For OL9/RHEL-native builds**, use Red Hat Universal Base Images:

```dockerfile
FROM registry.access.redhat.com/ubi9/go-toolset AS builder
WORKDIR /opt/app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o server .

FROM registry.access.redhat.com/ubi9/ubi-minimal
COPY --from=builder /opt/app/server /usr/local/bin/server
USER 1001
ENTRYPOINT ["/usr/local/bin/server"]
```

UBI-based images are Red Hat certified, have predictable CVE patching cycles, and are the recommended choice when running on Oracle Linux 9.

### 4.2 Build Happens Off the Server

The server is a runtime environment, not a build machine. Images are built on a developer machine or CI pipeline and pushed to a registry. The server pulls the pre-built image.

```bash
# On developer machine or CI:
podman build -t registry.example.com/myapp:1.0.0 .
podman push registry.example.com/myapp:1.0.0

# On the server:
podman pull registry.example.com/myapp:1.0.0
```

If no private registry is available, the image can be built locally on the server using `podman build`, but this requires the build toolchain and source code to be present on the server — which adds complexity and attack surface. A registry is the recommended approach.

### 4.3 Containerfile Conventions

- Use `.containerignore` (equivalent to `.dockerignore`) to exclude `.git`, test files, documentation, and any files not needed at build time
- Name stages explicitly with `AS <name>` for clarity and to support `--target` builds
- Order instructions from least-changed to most-changed to maximise layer cache hits (dependencies before source code)
- Add a `HEALTHCHECK` instruction so systemd and Quadlet can assess container health

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["/server", "--health-check"]
```

### 4.4 Image Versioning

Tag images with a specific version that maps to a git tag or commit. Never deploy `:latest` in production. Update the `Image=` line in the Quadlet unit when deploying a new version.

## 5. Reverse Proxy — Traefik

Traefik handles all inbound HTTP/HTTPS traffic. The application registers itself by creating a config file in `/etc/traefik/config/`. Traefik hot-reloads this directory — no restart is needed.

### 5.1 Route Config File

Create `/etc/traefik/config/<app-name>.yaml`:

```yaml
http:
  routers:
    <app-name>:
      rule: "Host(`<domain>`)"
      entryPoints:
        - websecure
      service: <app-name>-svc
      tls:
        certResolver: cloudflare
      # For public apps: no middleware needed.
      # For VPN-only apps: add wg-allowlist.
      # For VPN + Authelia: add admin-chain.

  services:
    <app-name>-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:<host-port>"
```

### 5.2 Domain Names

The application domain is completely independent of the admin stack domain. The `Host()` rule accepts any domain:

```yaml
# App on a different domain entirely
rule: "Host(`todo.somedomain.com`)"

# App on a subdomain of the admin domain
rule: "Host(`todo.${DOMAIN}`)"

# App on multiple domains
rule: "Host(`todo.somedomain.com`) || Host(`todo.anotherdomain.com`)"
```

**TLS across multiple domains:** The Cloudflare ACME resolver issues a separate certificate for each domain. The Cloudflare API token must have `Zone → DNS → Edit` permission on every domain used. If additional domains are in a different Cloudflare zone, the token must be scoped to include those zones.

### 5.3 Access Levels

Three access patterns are available via Traefik middleware:

| Pattern        | Middleware     | Who can access                            |
| -------------- | -------------- | ----------------------------------------- |
| Public         | _(none)_       | Anyone on the internet                    |
| VPN-only       | `wg-allowlist` | VPN-connected devices only, no login      |
| VPN + Authelia | `admin-chain`  | VPN-connected devices with Authelia login |

The `admin-chain` and `wg-allowlist` middlewares are defined in the stack's `infra.yaml` and available to all application route configs without redefinition.

### 5.4 DNS

Add a DNS record in Cloudflare for each application domain, pointing to the instance public IP, set to **DNS Only** (grey cloud). Traefik issues TLS certificates automatically on first request.

## 6. Security Headers and CSP

### 6.1 Global Headers (Stack-Provided)

The stack defines a `global-security-headers` middleware in `infra.yaml`. These headers are application-agnostic and safe to apply universally. Application Traefik route configs should reference this middleware:

```yaml
middlewares:
  global-security-headers:
    headers:
      stsSeconds: 31536000
      stsIncludeSubdomains: true
      stsPreload: false # Only enable after careful consideration
      forceSTSHeader: true
      frameDeny: true # X-Frame-Options: DENY
      contentTypeNosniff: true # X-Content-Type-Options: nosniff
      referrerPolicy: "strict-origin-when-cross-origin"
      permissionsPolicy: "camera=(), microphone=(), geolocation=()"
```

Add `global-security-headers` to the middleware chain of every router, including the `admin-chain`.

### 6.2 Content Security Policy — Application Responsibility

CSP cannot be defined globally because it is application-specific. A policy that allows `'unsafe-inline'` for a legacy app would weaken security for a hardened modern app. An app loading fonts from Google Fonts needs different rules than one that loads nothing externally.

**Three implementation options:**

#### Option A — Application Sets CSP (Recommended)

The application sets the `Content-Security-Policy` header in its HTTP responses. This is the most accurate approach because the application knows exactly what resources it loads. Traefik passes the header through untouched.

This is the correct approach for any application with control over its response headers (virtually all web frameworks support this via middleware — Helmet for Node.js, Django's `SecurityMiddleware`, Go's `net/http`).

#### Option B — Per-Route Traefik Middleware

If the application cannot set its own headers, define a CSP middleware in the application's Traefik config file:

```yaml
http:
  middlewares:
    <app-name>-csp:
      headers:
        contentSecurityPolicy: >-
          default-src 'self';
          script-src 'self';
          style-src 'self' 'unsafe-inline';
          img-src 'self' data:;
          font-src 'self';
          connect-src 'self';
          frame-ancestors 'none'

  routers:
    <app-name>:
      middlewares:
        - global-security-headers
        - <app-name>-csp
```

Keep this middleware in the application's own config file, not in `infra.yaml`.

#### Option C — Report-Only Mode for Development

During development, use `Content-Security-Policy-Report-Only` to observe violations without enforcing them:

```yaml
contentSecurityPolicyReportOnly: "default-src 'self'"
```

Switch to `contentSecurityPolicy` once the policy is validated.

### 6.3 CSP Design Principles

- Start with `default-src 'self'` and add only what is actually needed
- Avoid `'unsafe-inline'` and `'unsafe-eval'` — these negate most XSS protection
- Use nonces or hashes for inline scripts if they cannot be eliminated
- Treat CSP as a living document — review it when adding new frontend dependencies
- Test against [Mozilla Observatory](https://observatory.mozilla.org) before production deployment

## 7. Authentication and Authorization

Authentication (who are you?) and authorization (what are you allowed to do?) are distinct concerns. The stack provides infrastructure for authentication via Authelia. Authorization is always the application's responsibility.

### 7.1 The Four Patterns

#### Pattern A — Authelia for AuthN, Authelia Groups for Coarse AuthZ

Authelia handles login and TOTP. The application receives the authenticated user's identity via HTTP headers and uses Authelia group membership for coarse-grained access control (e.g. `admins` vs `users`).

```
Remote-User:   alice
Remote-Groups: admins,users
Remote-Name:   Alice Smith
Remote-Email:  alice@example.com
```

The application trusts these headers and grants access based on `Remote-Groups`. No application login page is needed.

**Best for:** Internal tools with a small, fixed set of users where group-level permissions are sufficient.

**Not suitable for:** Applications needing per-resource permissions, row-level security, or complex role hierarchies.

#### Pattern B — Authelia for AuthN, App-Owned Fine-Grained AuthZ

Authelia authenticates the user. The application receives identity headers and implements its own RBAC layer on top — per-resource permissions, ownership rules, audit trails. The application does not need its own login page but does maintain its own user/permission database.

This is the correct hybrid pattern. Authelia is the identity provider; the application is the authorization engine.

**Example for a Todo app:** Authelia confirms the user is authenticated. The app's own database records which todo lists belong to which user (`Remote-User` is the key), and enforces that users can only read and modify their own data.

**Best for:** Multi-user applications where each user owns data, or where permissions are too granular for Authelia groups to express.

#### Pattern C — App-Owned AuthN and AuthZ

The application manages its own user accounts, sessions, passwords, and permissions. Traefik routes traffic with no authentication middleware, or with only `wg-allowlist` for network-level restriction.

**Best for:** Public-facing applications with self-registration, applications integrating with external OAuth providers (Google, GitHub), or applications with requirements incompatible with Authelia's model.

#### Pattern D — VPN as Network Gate, App-Owned AuthN and AuthZ

The Traefik router applies `wg-allowlist` to restrict access to VPN-connected devices. The application handles its own user accounts and login. VPN membership provides a network-layer access restriction without requiring Authelia.

**Best for:** Applications intended for a specific team (all VPN peers) but requiring individual user accounts — for example, a multi-user Todo app used internally where team members each have their own login but the app is not public-facing.

### 7.2 Decision Guide

```
Is the app publicly accessible (open registration, external users)?
  Yes → Pattern C

Is the app internal with a small fixed set of users and group-level permissions sufficient?
  Yes → Pattern A

Is the app internal with individual user accounts and data ownership per user?
  VPN restriction desired → Pattern D
  No VPN restriction needed (public URL, app-managed access) → Pattern C

Does the app need Authelia login but also fine-grained per-resource authorization?
  Yes → Pattern B
```

### 7.3 Adding Authelia Users

When using Pattern A or B, new users are added to `/data/authelia/config/users_database.yaml`. TOTP enrollment happens through the Authelia portal at `https://auth.<domain>` on first login. See `stack-guide.md` Section 7.3 and 13.5 for user management and password rotation procedures.

## 8. Persistent Storage — Block Volume

The block volume is mounted at `/data/` and survives VM termination and redeployment. All persistent data must be stored here. Data inside the container or on the root filesystem is lost on container restart or VM replacement.

### 8.1 Directory Convention

```
/data/containers/<app-name>/
├── data/     ← primary application data (databases, uploads, settings)
├── logs/     ← application log files
├── config/   ← configuration files that change at runtime
└── env       ← environment file with secrets (mode 0600)
```

Create these directories before starting the container:

```bash
sudo mkdir -p \
  /data/containers/<app-name>/data \
  /data/containers/<app-name>/logs \
  /data/containers/<app-name>/config
```

### 8.2 Volume Mounts in Quadlet

Every volume mount must include the `:Z` SELinux label:

```ini
Volume=/data/containers/<app-name>/data:/app/data:Z
Volume=/data/containers/<app-name>/logs:/app/logs:Z
Volume=/data/containers/<app-name>/config:/app/config:Z
```

### 8.3 Database Placement

| Database engine            | Recommended path                             |
| -------------------------- | -------------------------------------------- |
| SQLite                     | `/data/containers/<app-name>/data/app.db`    |
| PostgreSQL (containerised) | `/data/containers/<app-name>/data/postgres/` |
| Redis                      | `/data/containers/<app-name>/data/redis/`    |
| File uploads               | `/data/containers/<app-name>/data/uploads/`  |

### 8.4 Multi-Container Applications

Applications with multiple containers (e.g. app + database + cache) use one Quadlet unit per container. Dependencies are expressed via systemd directives:

```ini
# In app.container — depends on the database starting first:
[Unit]
After=local-fs.target network-online.target postgres-<app-name>.service
Requires=local-fs.target postgres-<app-name>.service
```

Each container's data lives under the same parent directory:

```
/data/containers/<app-name>/
├── app/
├── postgres/
└── redis/
```

## 9. Secrets Management — OCI Vault

### 9.1 Creating an Application Secret

1. Go to **Security → Vault → Secrets → Create Secret** in the OCI Console
2. Name: `<app-name>-<purpose>` (e.g. `todo-db-password`, `todo-smtp-key`)
3. Content: plain text value
4. Copy the secret OCID

### 9.2 Fetching at Boot

Add a runcmd block in `cloud-config.example.yaml` to fetch the secret and write it to the application env file:

```bash
APP_SECRET=$(oci secrets secret-bundle get \
  --secret-id <secret-ocid> \
  --query "data.secretBundleContent.content" \
  --raw-output | base64 -d)

{
  echo "DATABASE_URL=postgres://user:${APP_SECRET}@localhost/mydb"
} >> /data/containers/<app-name>/env
chmod 600 /data/containers/<app-name>/env
```

### 9.3 Rules

- Never embed secrets in the container image
- Never commit secrets to version control
- Never write secrets outside `/data/` — the root filesystem is ephemeral
- Never log secret values

## 10. Logging

### 10.1 Application Logs

Write application logs to `/data/containers/<app-name>/logs/`. This ensures logs persist across VM replacement and are included in the Restic backup automatically.

Prefer structured (JSON) log output written to a file. If the application only supports stdout logging, logs are captured by journald but are not backed up:

```bash
sudo journalctl -u <app-name> -f
```

### 10.2 Access Logs

Traefik logs all HTTP access to `/data/logs/traefik/access.log` in JSON format. Application-level HTTP access logs are available there without any application-side configuration.

### 10.3 Log Rotation

For file-based logs, create `/etc/logrotate.d/<app-name>`:

```
/data/containers/<app-name>/logs/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 0640 root root
    postrotate
        systemctl reload <app-name> > /dev/null 2>&1 || true
    endscript
}
```

This can be added to `cloud-config.example.yaml` in the `write_files` section.

## 11. Backup

No application-level backup implementation is required or recommended. Restic backs up all of `/data/` automatically on a daily schedule. As long as the application stores all persistent data under `/data/containers/<app-name>/`, it is covered without any additional configuration.

### 11.1 Application Design Requirement

Do not implement application-specific backup logic. Do not use external managed database services outside `/data/` unless an independent backup strategy is explicitly documented.

### 11.2 Restore Verification

```bash
# After Restic restore, verify the application is healthy:
sudo systemctl start <app-name>
sudo systemctl status <app-name>
sudo journalctl -u <app-name> -n 50
```

## 12. TLS and Network Binding

### 12.1 TLS

The application must not manage TLS certificates. Traefik handles all TLS termination. Traffic from Traefik to the application travels over `127.0.0.1` without TLS — this is correct and intentional since the loopback interface does not leave the host.

The application must accept plain HTTP on its internal port. Configuring the application for HTTPS internally will cause Traefik's backend connection to fail.

### 12.2 Network Binding

All application ports must bind exclusively to `127.0.0.1`. Never bind to `0.0.0.0`.

```ini
# In Quadlet unit:
PublishPort=127.0.0.1:<host-port>:<container-port>
```

### 12.3 Port Allocation

Verify the chosen port is unused before deployment:

```bash
sudo ss -tlnp | grep <port>
```

Ports reserved by the stack:

| Port  | Service                               |
| ----- | ------------------------------------- |
| 80    | Traefik HTTP                          |
| 443   | Traefik HTTPS                         |
| 8082  | Traefik Prometheus metrics (internal) |
| 9090  | Cockpit                               |
| 9091  | Authelia                              |
| 51820 | WireGuard (UDP)                       |
| 51821 | wg-easy management UI                 |

## 13. Monitoring

PCP (Performance Co-Pilot) collects host-level metrics. The Prometheus endpoint at `https://metrics.<domain>` exposes Traefik router, service, and middleware metrics. These are available without any application-side configuration.

If the application exposes a `/metrics` endpoint in Prometheus format, expose it via a separate Traefik route restricted to `admin-chain`:

```yaml
# In /etc/traefik/config/<app-name>-metrics.yaml:
http:
  routers:
    <app-name>-metrics:
      rule: "Host(`metrics-<app-name>.<domain>`)"
      entryPoints:
        - websecure
      service: <app-name>-metrics-svc
      middlewares:
        - admin-chain
      tls:
        certResolver: cloudflare

  services:
    <app-name>-metrics-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:<metrics-port>"
```

## 14. SELinux Considerations

Oracle Linux 9 runs with SELinux in enforcing mode. Every volume mount in a Quadlet unit must include the `:Z` flag — without it, SELinux will deny the container access to the mounted path, typically producing silent permission denied errors inside the container.

```ini
# Correct
Volume=/data/containers/myapp/data:/app/data:Z

# Incorrect — will fail at runtime with no obvious error
Volume=/data/containers/myapp/data:/app/data
```

If the application requires additional Linux capabilities:

```ini
[Container]
AddCapability=NET_ADMIN
```

Never use `SecurityLabelDisable=true` unless there is no other option, and document why.

## 15. Automated Deployment Across VM Replacement

On VM replacement, cloud-init re-provisions the OS but application-specific Quadlet and Traefik config files do not exist on the new instance. Two strategies exist:

### 15.1 Strategy A — Add Applications to cloud-config.example.yaml

Add the application's directory creation, env file setup, Quadlet unit, and Traefik config to the `write_files` and `runcmd` sections of `cloud-config.example.yaml`. The application becomes part of the immutable infrastructure definition and starts automatically on every new instance.

**Best for:** Applications that are permanent parts of the stack, always deployed together with the infrastructure.

### 15.2 Strategy B — App Manifest Directory (Recommended for Optional Apps)

Applications register themselves by saving a deployment manifest to `/data/apps/`. On VM replacement, cloud-init executes all manifests in that directory, reconstructing all registered applications automatically without any change to `cloud-config.example.yaml`.

**Directory structure on the block volume:**

```
/data/apps/
└── todo.sh         ← deployment manifest for the Todo app
└── another-app.sh  ← deployment manifest for another app
```

**How `deploy-service.sh` saves a manifest:**

The script creates the Quadlet and Traefik files and saves its own invocation as a manifest using brace-grouped `echo` statements (heredocs cannot be used inside YAML literal block scalars):

```bash
MANIFEST_FILE="/data/apps/${NAME}.sh"
mkdir -p /data/apps
{
  echo "#!/usr/bin/env bash"
  echo "# Auto-generated deployment manifest for ${NAME}"
  echo "# Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "$(realpath "$0") \\"
  echo "  --name ${NAME} \\"
  echo "  --image ${IMAGE} \\"
  echo "  --port ${PORT} \\"
  echo "  --domain ${DOMAIN} \\"
  for vol in "${VOLUMES[@]+"${VOLUMES[@]}"}"; do
    echo "  --volume ${vol} \\"
  done
  for env_var in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
    echo "  --env ${env_var} \\"
  done
  [[ "$ADMIN" == "true" ]] && echo "  --admin \\"
  echo '  "$@"'
} > "$MANIFEST_FILE"
chmod 755 "$MANIFEST_FILE"
```

**cloud-config.example.yaml runcmd block to replay manifests on boot:**

```yaml
# -----------------------------------------------------------
# Replay Application Deployment Manifests
# Reconstructs Quadlet and Traefik configs for all registered
# applications from manifests stored on the block volume.
# Skipped silently on clean first boot (no manifests yet).
# -----------------------------------------------------------
- |
    if [ -d /data/apps ] && ls /data/apps/*.sh 2>/dev/null | grep -q .; then
    for manifest in /data/apps/*.sh; do
      echo "Replaying manifest: ${manifest}"
      bash "${manifest}" || echo "WARNING: manifest failed: ${manifest}"
    done
    systemctl daemon-reload
  fi
```

**Manifest lifecycle:**

- Created automatically by `deploy-service.sh` when deploying an app
- Updated when `deploy-service.sh` is run again with the same `--name`
- Deleted manually when an application is permanently removed:
  ```bash
  sudo systemctl disable --now <app-name>
  sudo rm /etc/containers/systemd/<app-name>.container
  sudo rm /etc/traefik/config/<app-name>.yaml
  sudo rm /data/apps/<app-name>.sh
  ```

## 16. Deployment Workflow

### 16.1 First Deployment

1. Build and push the container image (see Section 4)
2. Create persistent directories:

   ```bash
   sudo mkdir -p \
     /data/containers/<app-name>/data \
     /data/containers/<app-name>/logs \
     /data/containers/<app-name>/config
   sudo touch /data/containers/<app-name>/env
   sudo chmod 600 /data/containers/<app-name>/env
   ```

3. Deploy using the deploy script:

   ```bash
   sudo ./deploy-service.sh \
     --name <app-name> \
     --image <image>:<tag> \
     --port <port> \
     --domain <domain>
   ```

4. Add the DNS record in Cloudflare (DNS Only, grey cloud)
5. Verify:
   ```bash
   sudo systemctl status <app-name>
   # Wait ~60 seconds for TLS certificate issuance, then:
   curl -I https://<domain>
   ```

### 16.2 Updating the Application

```bash
# Pull the new image
sudo podman pull <image>:<new-tag>

# Update the image tag in the Quadlet unit
sudo sed -i 's|<image>:<old-tag>|<image>:<new-tag>|' \
  /etc/containers/systemd/<app-name>.container

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart <app-name>
```

## 17. Integration Checklist

### Architecture and Design

- [ ] Authentication and authorization pattern decided (Section 7.2 decision guide)
- [ ] All persistent data paths identified and mapped to `/data/containers/<app-name>/`
- [ ] Domain name decided — independent domain or subdomain of admin domain
- [ ] Cloudflare token has `Zone → DNS → Edit` permission on the application domain
- [ ] Port chosen and verified as unused (Section 12.3)
- [ ] Multi-container dependencies mapped if applicable (Section 8.4)
- [ ] Secrets identified and OCI Vault secrets created (Section 9.1)
- [ ] CSP strategy decided — app-set headers or per-route Traefik middleware (Section 6.2)

### Container Image

- [ ] Multi-stage `Containerfile` used for compiled languages (Section 4.1)
- [ ] Build toolchain not present in production image
- [ ] `.containerignore` file created
- [ ] Image tagged with a specific version, not `:latest`
- [ ] `HEALTHCHECK` instruction added to `Containerfile`
- [ ] Application accepts plain HTTP on internal port (no internal TLS)

### Configuration Files

- [ ] Quadlet `.container` file created in `/etc/containers/systemd/`
- [ ] Traefik route config created in `/etc/traefik/config/<app-name>.yaml`
- [ ] DNS record created in Cloudflare (DNS Only)
- [ ] Logrotate config created if using file-based logging (Section 10.3)
- [ ] Env file created at `/data/containers/<app-name>/env` with mode `0600`
- [ ] Deployment manifest saved to `/data/apps/<app-name>.sh` (Section 15.2)

### Runtime Verification

- [ ] Container starts and stays running: `systemctl status <app-name>`
- [ ] Application is reachable via its domain
- [ ] TLS certificate issued — HTTPS loads without browser warning
- [ ] Authentication works as expected for chosen pattern
- [ ] Data persists across a container restart
- [ ] Logs appear in `/data/containers/<app-name>/logs/`

### Integration Correctness

- [ ] All ports bound to `127.0.0.1` only — verified with `ss -tlnp`
- [ ] All volume mounts include `:Z` SELinux flag
- [ ] No secrets embedded in image or unit files
- [ ] Data stored under `/data/containers/<app-name>/` — not on root filesystem
- [ ] CSP header set and validated (Section 6.3)
