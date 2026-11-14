---
name: "Adding Applications"
description: |
  How to build, deploy, route, secure, and persist an application container in the OCI secure stack.
status: draft
version: 1.2
updated: 2026-11-14
---

# Adding Applications

This guide is for application developers and architects deploying a container into the stack. It defines the integration points between the stack and the application. It states which responsibilities belong to the stack and which belong to the application.

The stack owns routing, TLS termination, authentication infrastructure, persistent storage, backup, and service management. The application owns its business logic, data model, and user-facing behaviour.

## 1. Responsibility boundaries

| Layer                                         | Mandatory            | Optional |
| --------------------------------------------- | -------------------- | -------- |
| Podman Quadlet for container lifecycle        | Yes                  | No       |
| Traefik for HTTP routing and TLS              | Yes                  | No       |
| `127.0.0.1` network binding                   | Yes                  | No       |
| `/data/containers/<app>/` for persistent data | Yes                  | No       |
| Restic backup via `/data/`                    | Yes, automatic       | No       |
| Authelia for authentication                   | No                   | Yes      |
| OCI Vault for secrets                         | No                   | Yes      |
| Stack logging conventions                     | No                   | Yes      |
| OpenMetrics exposure for PCP ingestion        | Yes, where supported | No       |

| Concern                       | Stack owns                                        | Application owns                                        |
| ----------------------------- | ------------------------------------------------- | ------------------------------------------------------- |
| TLS certificates              | Issuance, renewal, termination                    | Nothing                                                 |
| HTTP routing                  | Domain assignment, middleware chains              | Route config file in `/etc/traefik/config/`             |
| Global security headers       | HSTS, `X-Frame-Options`, `X-Content-Type-Options` | Content-Security-Policy                                 |
| Authentication infrastructure | Authelia SSO                                      | Auth integration choice                                 |
| Authorization                 | Coarse group-based via Authelia                   | Fine-grained RBAC in the application                    |
| Container lifecycle           | systemd via Quadlet                               | Image, ports, environment, health                       |
| Persistent storage            | Block volume mount at `/data/`                    | Directory structure under `/data/containers/<app>/`     |
| Backup                        | Restic covers all of `/data/`                     | Storing data under `/data/containers/<app>/`            |
| Secret storage                | OCI Vault infrastructure                          | Creating and referencing application secrets            |
| Logging infrastructure        | Journal, Traefik access logs                      | Application log output and rotation                     |
| Monitoring infrastructure     | PCP, `pmproxy`, Grafana, OpenMetrics ingestion    | Exposing a loopback `/metrics` endpoint where supported |
| OS security                   | SELinux, auditd, firewall                         | `:Z` volume flag, no privileged containers              |
| Networking                    | Firewall, public port exposure                    | Binding to `127.0.0.1` only                             |
| VM lifecycle                  | Cloud-init, block volume                          | Nothing                                                 |

## 2. Container runtime

All application containers use Podman Quadlet. `podman-compose`, `docker-compose`, and manual `podman run` commands are not used.

### 2.1 Quadlet unit

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

`Requires=local-fs.target` is mandatory. It ensures the block volume is mounted before the container starts on every boot.

### 2.2 Rules

- Never use `--privileged`. Request only the capabilities the container needs with `AddCapability=`.
- Never bind to `0.0.0.0`. Bind all ports to `127.0.0.1`.
- Pin image versions. Do not use `:latest` in production.
- Use `EnvironmentFile=`. Do not embed secrets in the unit file or image.

### 2.3 Activation

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now <app-name>

sudo systemctl status <app-name>
sudo journalctl -u <app-name> -n 50
```

## 3. Build the image

Podman uses `Containerfile` as the canonical filename. The syntax is the same as Dockerfile.

### 3.1 Multi-stage builds

For compiled languages, the build toolchain must not be in the production image. Use a multi-stage `Containerfile`.

Go example:

```dockerfile
FROM docker.io/library/golang:1.22 AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-w -s" \
    -o /app/server .

FROM scratch

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /app/server /server

EXPOSE 8080
ENTRYPOINT ["/server"]
```

For Oracle Linux 9 native builds, use Red Hat Universal Base Images:

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

UBI-based images are Red Hat certified, have predictable CVE patching cycles, and are the recommended choice on Oracle Linux 9.

### 3.2 Build off the server

The server is a runtime environment, not a build machine. Build and push images on a developer machine or CI pipeline.

```bash
podman build -t registry.example.com/myapp:1.0.0 .
podman push registry.example.com/myapp:1.0.0
```

On the server:

```bash
podman pull registry.example.com/myapp:1.0.0
```

You can build on the server. This adds the toolchain and source code to the server and increases the attack surface.

### 3.3 Containerfile conventions

- Use `.containerignore` to exclude `.git`, tests, documentation, and files not needed at build time.
- Name stages with `AS <name>` to support `--target` builds.
- Order instructions from least-changed to most-changed for layer cache hits.
- Add a `HEALTHCHECK` so systemd and Quadlet can assess container health.

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["/server", "--health-check"]
```

### 3.4 Image versioning

Tag images with a specific version that maps to a git tag or commit. Update the `Image=` line in the Quadlet unit when deploying a new version.

## 4. Traefik routing

Traefik handles all inbound HTTP and HTTPS traffic. The application registers itself by creating a config file in `/etc/traefik/config/`. Traefik hot-reloads this directory; no restart is needed.

### 4.1 Route file

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
      # Public: no middleware.
      # VPN-only: add wg-allowlist.
      # VPN plus Authelia: add admin-chain.

  services:
    <app-name>-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:<host-port>"
```

### 4.2 Domains

The application domain is independent of the admin domain. `Host()` accepts any domain:

```yaml
rule: "Host(`todo.somedomain.com`)"
rule: "Host(`todo.${DOMAIN}`)"
rule: "Host(`todo.somedomain.com`) || Host(`todo.anotherdomain.com`)"
```

The Cloudflare ACME resolver issues a separate certificate for each domain. The Cloudflare token must have `Zone → DNS → Edit` on every domain used. If additional domains are in another Cloudflare zone, the token must cover that zone.

### 4.3 Access levels

| Pattern      | Middleware     | Who can access                            |
| ------------ | -------------- | ----------------------------------------- |
| Public       | None           | Anyone on the internet                    |
| VPN-only     | `wg-allowlist` | VPN-connected devices, no login           |
| VPN plus SSO | `admin-chain`  | VPN-connected devices with Authelia login |

`admin-chain` and `wg-allowlist` are defined in the stack infrastructure configuration and are available to application route configs without redefinition.

### 4.4 DNS

Add a Cloudflare DNS record for each application domain. Point it to the instance public IP and set it to DNS Only, grey cloud. Traefik issues TLS certificates automatically on the first request.

## 5. Security headers and CSP

### 5.1 Global headers

The stack defines a `global-security-headers` middleware in `00-infra.yaml`:

```yaml
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
```

Add `global-security-headers` to every router, including `admin-chain`.

### 5.2 Content Security Policy

CSP is application-specific and must not be defined globally. A policy that allows `'unsafe-inline'` for one application weakens every application that shares it.

Option A, recommended: the application sets `Content-Security-Policy` in its responses. The application knows its resources and Traefik passes the header through.

Option B: if the application cannot set its own header, define a per-route middleware in the application's Traefik config:

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

Keep this middleware in the application's own config file, not in `00-infra.yaml`.

Option C: during development, use `Content-Security-Policy-Report-Only` to observe violations without enforcing them. Switch to enforcing mode after the policy is validated.

CSP principles:

- Start with `default-src 'self'` and add only what is needed.
- Avoid `'unsafe-inline'` and `'unsafe-eval'`.
- Use nonces or hashes for inline scripts that cannot be eliminated.
- Review the policy when frontend dependencies change.
- Test with Mozilla Observatory before production.

## 6. Authentication and authorization

Authentication and authorization are separate. The stack provides authentication infrastructure through Authelia. Authorization is always the application's responsibility.

### 6.1 Patterns

Pattern A: Authelia handles login and TOTP. The application receives identity headers and uses Authelia groups for coarse access control:

```text
Remote-User:   alice
Remote-Groups: admins,users
Remote-Name:   Alice Smith
Remote-Email:  alice@example.com
```

Use this for internal tools with a small fixed user set and group-level permissions. It is not suitable for per-resource permissions or row-level security.

Pattern B: Authelia authenticates the user. The application receives identity headers and implements its own RBAC for per-resource permissions, ownership, and audit trails. This is the correct hybrid pattern for multi-user applications where each user owns data.

Pattern C: the application manages its own accounts, sessions, passwords, and permissions. Traefik routes traffic with no authentication middleware, or with `wg-allowlist` only. Use this for public applications with self-registration or external OAuth.

Pattern D: Traefik applies `wg-allowlist` to restrict access to VPN-connected devices. The application handles its own user accounts and login. Use this for internal applications with individual user accounts.

### 6.2 Decision guide

```text
Is the app publicly accessible with open registration or external users?
  Yes -> Pattern C

Is the app internal with a small fixed user set and group-level permissions?
  Yes -> Pattern A

Is the app internal with individual user accounts and data ownership?
  VPN restriction desired -> Pattern D
  No VPN restriction needed -> Pattern C

Does the app need Authelia login plus fine-grained per-resource authorization?
  Yes -> Pattern B
```

### 6.3 Adding Authelia users

When using Pattern A or B, add users to `/data/authelia/config/users_database.yaml`. TOTP enrollment happens through the Authelia portal at `https://auth.<domain>` on first login. Password rotation is covered in `docs/guides/operations.md`.

## 7. Persistent storage

The block volume is mounted at `/data/` and survives VM termination and redeployment. All persistent data must be stored there. Data inside the container or on the root filesystem is lost on container restart or VM replacement.

### 7.1 Directory convention

```text
/data/containers/<app-name>/
├── data/     # primary application data
├── logs/     # application log files
├── config/   # configuration files that change at runtime
└── env       # environment file with secrets, mode 0600
```

Create the directories before starting the container:

```bash
sudo mkdir -p \
  /data/containers/<app-name>/data \
  /data/containers/<app-name>/logs \
  /data/containers/<app-name>/config
```

### 7.2 Volume mounts

Every volume mount must include the `:Z` SELinux label:

```ini
Volume=/data/containers/<app-name>/data:/app/data:Z
Volume=/data/containers/<app-name>/logs:/app/logs:Z
Volume=/data/containers/<app-name>/config:/app/config:Z
```

### 7.3 Database placement

| Database engine           | Recommended path                             |
| ------------------------- | -------------------------------------------- |
| SQLite                    | `/data/containers/<app-name>/data/app.db`    |
| PostgreSQL, containerised | `/data/containers/<app-name>/data/postgres/` |
| Redis                     | `/data/containers/<app-name>/data/redis/`    |
| File uploads              | `/data/containers/<app-name>/data/uploads/`  |

### 7.4 Multi-container applications

Use one Quadlet unit per container. Express dependencies with systemd directives:

```ini
# In app.container, depends on the database starting first
[Unit]
After=local-fs.target network-online.target postgres-<app-name>.service
Requires=local-fs.target postgres-<app-name>.service
```

Each container's data lives under the same parent directory:

```text
/data/containers/<app-name>/
├── app/
├── postgres/
└── redis/
```

## 8. Secrets

### 8.1 Create a secret

1. In OCI Console, go to **Security → Vault → Secrets → Create Secret**.
2. Name it `<app-name>-<purpose>`, for example `todo-db-password`.
3. Use the plain text value as the content.
4. Copy the secret OCID.

### 8.2 Fetch at boot

Add a `runcmd` block to `infra/cloud-init/cloud-config.example.yaml` that fetches the secret and writes the application environment file:

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

### 8.3 Rules

- Never embed secrets in the container image.
- Never commit secrets to version control.
- Never write secrets outside `/data/`.
- Never log secret values.
- Use Podman secrets or root-only environment files. Do not write secret values into world-readable manifests.

## 9. Logging

### 9.1 Application logs

Write application logs to `/data/containers/<app-name>/logs/`. This keeps logs across VM replacement and includes them in the Restic backup.

Prefer structured JSON output written to a file. If the application only supports stdout, journald captures it but the log is not backed up:

```bash
sudo journalctl -u <app-name> -f
```

### 9.2 Access logs

Traefik writes HTTP access logs to `/data/logs/traefik/access.log` in JSON format. Application-level HTTP access logs are available there without application-side configuration.

### 9.3 Log rotation

For file-based logs, create `/etc/logrotate.d/<app-name>`:

```text
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

Add this to the `write_files` section of `infra/cloud-init/cloud-config.example.yaml`.

## 10. Backup

No application-level backup implementation is required. Restic backs up all of `/data/` daily. Store all persistent data under `/data/containers/<app-name>/` and it is covered.

Do not implement application-specific backup logic. Do not use external managed database services outside `/data/` unless an independent backup strategy is documented.

After a restore, verify the application:

```bash
sudo systemctl start <app-name>
sudo systemctl status <app-name>
sudo journalctl -u <app-name> -n 50
```

## 11. TLS and network binding

### 11.1 TLS

The application must not manage TLS certificates. Traefik handles all TLS termination. Traffic from Traefik to the application travels over `127.0.0.1` without TLS. This is correct because the loopback interface does not leave the host.

The application must accept plain HTTP on its internal port. Configuring internal HTTPS causes the Traefik backend connection to fail.

### 11.2 Network binding

All application ports must bind to `127.0.0.1` only. Never bind to `0.0.0.0`.

```ini
PublishPort=127.0.0.1:<host-port>:<container-port>
```

### 11.3 Port allocation

Verify the chosen port is unused:

```bash
sudo ss -tlnp | grep <port>
```

Ports reserved by the stack:

| Port  | Service                              |
| ----- | ------------------------------------ |
| 80    | Traefik HTTP                         |
| 443   | Traefik HTTPS                        |
| 3000  | Grafana, loopback                    |
| 6379  | Valkey, loopback, history profile    |
| 8082  | Traefik Prometheus metrics, internal |
| 9090  | Cockpit                              |
| 9091  | Authelia                             |
| 44322 | PCP pmproxy, loopback                |
| 51820 | WireGuard, UDP                       |
| 51821 | wg-easy management UI                |

## 12. Monitoring

PCP collects host metrics through `pmcd` and exposes them through `pmproxy` on `127.0.0.1:44322`. Grafana reads `pmproxy` through the PCP Vector datasource. The live profile is default. The history profile adds Valkey for `pmseries` retention. The monitoring profiles and capacity minimums are canonical in `docs/reference/infrastructure.md` section 8.

The OpenMetrics PMDA collects Traefik metrics from `127.0.0.1:8082`. The stack also creates `/etc/pcp/openmetrics/traefik.url`.

If the image supports a Prometheus or OpenMetrics endpoint, expose it on `127.0.0.1` and add a URL file to the OpenMetrics PMDA. This endpoint is the primary telemetry for rootless application containers because the Podman PMDA covers rootful containers only. Do not create a Traefik route for the metrics endpoint. If the image does not support metrics, record that limitation and rely on journald and on-demand `podman stats`.

```bash
sudo install -d -m 0755 /etc/pcp/openmetrics
sudo tee /etc/pcp/openmetrics/<app-name>.url >/dev/null <<'EOF'
http://127.0.0.1:<metrics-port>/metrics
EOF
sudo install -d -m 0755 /var/lib/pcp/pmdas/openmetrics/config.d
sudo ln -sfn /etc/pcp/openmetrics/<app-name>.url \
  /var/lib/pcp/pmdas/openmetrics/config.d/<app-name>.url
sudo systemctl restart pmcd
```

Verify the PMDA sees the new URL:

```bash
pminfo -f openmetrics.control
```

The application must bind its metrics listener to `127.0.0.1`. Do not expose a `metrics-<app-name>.<domain>` hostname. Do not open the metrics port in firewalld or the OCI network rules. An external Prometheus server can scrape `pmproxy` later through a secure tunnel.

## 13. SELinux

Oracle Linux 9 runs SELinux in enforcing mode. Every volume mount in a Quadlet unit must include the `:Z` flag. Without it, SELinux denies access to the mounted path and the container fails with a permission error.

```ini
# Correct
Volume=/data/containers/myapp/data:/app/data:Z

# Incorrect, fails at runtime
Volume=/data/containers/myapp/data:/app/data
```

If the application needs additional capabilities:

```ini
[Container]
AddCapability=NET_ADMIN
```

Do not use `SecurityLabelDisable=true` unless there is no alternative, and document why.

## 14. Reconstruct applications after VM replacement

On VM replacement, cloud-init re-provisions the OS. Application-specific Quadlet and Traefik config files do not exist on the new instance. Two strategies exist.

### 14.1 Strategy A: add the application to cloud-config

Add the directory creation, environment file, Quadlet unit, and Traefik config to the `write_files` and `runcmd` sections. Edit `infra/cloud-init/cloud-config.example.yaml`. The application then becomes part of the immutable infrastructure definition and starts on every new instance.

Use this for applications that are permanent parts of the stack.

### 14.2 Strategy B: application manifests

Applications register themselves by saving a deployment manifest to `/data/apps/`. On VM replacement, cloud-init executes all manifests and reconstructs the applications without changing `infra/cloud-init/cloud-config.example.yaml`.

```text
/data/apps/
├── todo.sh
└── another-app.sh
```

`infra/host/deploy-service.sh` saves its own invocation as a manifest. The manifest records the application name, image, port, domain, volumes, environment, and admin flag. The cloud-init replay block is:

```bash
if [ -d /data/apps ] && ls /data/apps/*.sh 2>/dev/null | grep -q .; then
  for manifest in /data/apps/*.sh; do
    echo "Replaying manifest: ${manifest}"
    bash "${manifest}" || echo "WARNING: manifest failed: ${manifest}"
  done
  systemctl daemon-reload
fi
```

Manifest lifecycle:

- Created when `infra/host/deploy-service.sh` deploys an application.
- Updated when the same application name is deployed again.
- Deleted manually when an application is permanently removed.

Remove an application:

```bash
sudo systemctl disable --now <app-name>
sudo rm /etc/containers/systemd/<app-name>.container
sudo rm /etc/traefik/config/<app-name>.yaml
sudo rm /data/apps/<app-name>.sh
sudo systemctl daemon-reload
```

## 15. Deployment workflow

### 15.1 First deployment

1. Build and push the container image.
2. Create the persistent directories:

   ```bash
   sudo mkdir -p \
     /data/containers/<app-name>/data \
     /data/containers/<app-name>/logs \
     /data/containers/<app-name>/config
   sudo touch /data/containers/<app-name>/env
   sudo chmod 600 /data/containers/<app-name>/env
   ```

3. Deploy with the script:

   ```bash
   sudo ./infra/host/deploy-service.sh \
     --name <app-name> \
     --image <image>:<tag> \
     --port <port> \
     --domain <domain>
   ```

4. Confirm the wildcard DNS record covers `<domain>`. Add a specific DNS Only record only if it does not.
5. Verify:

   ```bash
   sudo systemctl status <app-name>
   curl -I https://<domain>
   ```

Wait about 60 seconds for certificate issuance.

### 15.2 Update the application

```bash
sudo podman pull <image>:<new-tag>

sudo sed -i 's|<image>:<old-tag>|<image>:<new-tag>|' \
  /etc/containers/systemd/<app-name>.container

sudo systemctl daemon-reload
sudo systemctl restart <app-name>
```

### 15.3 Test the deployment script

Always use `--dry-run` before deploying a new service:

```bash
sudo ./infra/host/deploy-service.sh \
  --name testapp \
  --image nginx:latest \
  --port 8080 \
  --domain test.yourdomain.com \
  --dry-run
```

Inspect the generated Quadlet and Traefik files printed to stdout. Verify indentation, port binding, volume paths, and middleware before writing to disk.

Deploy a test service:

```bash
sudo ./infra/host/deploy-service.sh \
  --name testapp \
  --image nginx:latest \
  --port 8080 \
  --domain test.yourdomain.com

sudo systemctl status testapp
sudo journalctl -u traefik.service -n 20
curl -I https://test.yourdomain.com
```

Verify the manifest and test replay:

```bash
cat /data/apps/testapp.sh
sudo bash /data/apps/testapp.sh --dry-run
```

Clean up the test service:

```bash
sudo systemctl disable --now testapp
sudo rm /etc/containers/systemd/testapp.container
sudo rm /etc/traefik/config/testapp.yaml
sudo rm /data/apps/testapp.sh
sudo systemctl daemon-reload
```

## 16. Integration checklist

### Architecture and design

- [ ] Authentication and authorization pattern selected.
- [ ] All persistent data paths mapped to `/data/containers/<app-name>/`.
- [ ] Domain name selected.
- [ ] Cloudflare token has `Zone → DNS → Edit` on the application domain.
- [ ] Port checked as unused.
- [ ] Multi-container dependencies mapped.
- [ ] Secrets identified and created in OCI Vault.
- [ ] CSP strategy selected.

### Container image

- [ ] Multi-stage `Containerfile` used for compiled languages.
- [ ] Build toolchain absent from the production image.
- [ ] `.containerignore` created.
- [ ] Image tagged with a specific version, not `:latest`.
- [ ] `HEALTHCHECK` added.
- [ ] Application accepts plain HTTP on its internal port.

### Configuration files

- [ ] Quadlet `.container` file in `/etc/containers/systemd/`.
- [ ] Traefik route config in `/etc/traefik/config/<app-name>.yaml`.
- [ ] DNS record in Cloudflare, DNS Only.
- [ ] Logrotate config created for file-based logging.
- [ ] Environment file at `/data/containers/<app-name>/env`, mode `0600`.
- [ ] Deployment manifest saved to `/data/apps/<app-name>.sh`.

### Runtime verification

- [ ] Container starts and stays running.
- [ ] Application reachable through its domain.
- [ ] TLS certificate issued without a browser warning.
- [ ] Authentication works for the selected pattern.
- [ ] Data persists across a container restart.
- [ ] Logs appear in `/data/containers/<app-name>/logs/`.

### Integration correctness

- [ ] All ports bound to `127.0.0.1`, verified with `ss -tlnp`.
- [ ] All volume mounts include `:Z`.
- [ ] No secrets in the image or unit files.
- [ ] Data stored under `/data/containers/<app-name>/`.
- [ ] CSP header set and validated.

## Related documents

- Design: `docs/architecture.md`
- Operations: `docs/guides/operations.md`
- Application manifest reference: `docs/reference/application-manifest.md`
- ADR-005, application container contract: `docs/decisions/005-application-contract.md`
