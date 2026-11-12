---
name: "Secure Admin Stack Guide"
description: |
  Architecture, deployment, operations, and security guide for the OCI Oracle Linux 9 secure admin stack. Legacy document retained during the documentation migration.
status: legacy
version: 1.0
updated: 2026-09-04
---

# OCI Oracle Linux 9 — Secure Admin Stack

## Architecture & Operations Guide

> **Companion document to `cloud-config.example.yaml`**\
> Assumes the OCI instance, block volume, Vault, and DNS zone are already provisioned.

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Component Roles](#2-component-roles)
3. [Traffic Flows](#3-traffic-flows)
4. [Access Model & Methodology](#4-access-model--methodology)
5. [Prerequisites & Provisioning Checklist](#5-prerequisites--provisioning-checklist)
6. [Template Variables & Deployment](#6-template-variables--deployment)
7. [OCI Vault — Creating Secrets](#7-oci-vault--creating-secrets)
8. [DNS Configuration](#8-dns-configuration)
9. [Block Volume — Persistent Storage Layout](#9-block-volume--persistent-storage-layout)
10. [WireGuard — Peer Management via wg-easy](#10-wireguard--peer-management-via-wg-easy)
11. [Post-Deployment Verification](#11-post-deployment-verification)
12. [Adding Podman Container Services](#12-adding-podman-container-services)
13. [Maintenance & Operations](#13-maintenance--operations)
14. [Security Reference](#14-security-reference)

## 1. Architecture Overview

```text
                           INTERNET
                              │
         ┌────────────────────┼──────────────────────┐
         │                    │                      │
    :51820/udp           :80 (→ 443)             :443/tcp
         │                    │                      │
   ┌─────▼─────┐     ┌────────▼──────────────────────▼────────┐
   │ WireGuard │     │             Traefik v3                 │
   │    VPN    │     │            (Edge Router)               │
   └─────┬─────┘     └────────┬──────────────────────┬────────┘
         │                    │                      │
 10.0.0.0/24 (VPN)       admin routes          public routes
         │                    │                      │
┌────────▼───────┐   ┌────────▼────────┐     ┌───────▼────────┐
│  Admin Access  │   │    Authelia     │     │     Podman     │
│   a 10.0.0.x   │   │  (forwardAuth)  │     │   Containers   │
│  address only  │   └────────┬────────┘     └────────────────┘
└────────────────┘            │
                ┌─────────────┼─────────────┐
                │             │             │
           ┌────▼────┐  ┌─────▼─────┐  ┌────▼─────┐
           │ Cockpit │  │ Dashboard │  │ wg-easy  │
           │  :9090  │  │  Metrics  │  │ (Podman) │
           └─────────┘  └───────────┘  └──────────┘
```

### Key Principle

WireGuard and Traefik are parallel services. WireGuard provides the encrypted tunnel that puts a client device on the `10.0.0.0/24` VPN subnet. Traefik's `ipAllowList` middleware enforces that all admin-facing routes (`traefik.*`, `metrics.*`, `cockpit.*`, `wg.*`) are only reachable from that subnet. For those routes, Traefik delegates authentication to Authelia via `forwardAuth` — providing a single, unified login with TOTP across all admin services. Application and public services go through Traefik without the VPN restriction or Authelia.

### Immutable Infrastructure

The VM is treated as a disposable execution environment — it is never patched or reconfigured in place. When an update is needed, a new instance is provisioned from scratch using the same `cloud-config.example.yaml`, the block volume is reattached, and the old instance is terminated. All state lives either on the block volume (`/data`) or in OCI Vault. The VM itself is stateless and replaceable in under 10 minutes. This eliminates configuration drift, simplifies disaster recovery, and means the deployment process is exercised every time a new instance is created.

## 2. Component Roles

| Component              | Role                                   | Exposed Port            | Auth                       |
| ---------------------- | -------------------------------------- | ----------------------- | -------------------------- |
| **Traefik**            | Edge router, TLS termination, routing  | 80, 443 (public)        | —                          |
| **WireGuard**          | VPN tunnel for admin access            | 51820/UDP (public)      | Peer public key            |
| **Authelia**           | SSO & MFA gateway for all admin routes | internal (Podman)       | —                          |
| **Traefik Dashboard**  | Router/middleware/service inspection   | via `traefik.${DOMAIN}` | Authelia (password + TOTP) |
| **Prometheus Metrics** | Performance metrics endpoint           | via `metrics.${DOMAIN}` | Authelia (password only)   |
| **Cockpit**            | Full OS web console                    | via `cockpit.${DOMAIN}` | Authelia (password + TOTP) |
| **wg-easy**            | WireGuard peer management UI           | via `wg.${DOMAIN}`      | Authelia (password + TOTP) |
| **Podman Containers**  | Application workloads                  | via their hostnames     | Per-app                    |

## 3. Traffic Flows

### 3.1 Public Application Traffic (no VPN required)

```
Browser → app.${DOMAIN}:443
  → Traefik (TLS termination via Cloudflare DNS-01)
  → Podman container on 127.0.0.1:<port>
  → Response
```

No VPN. No IP restriction. Authentication is configured per-service in each container's Traefik dynamic config file.

### 3.2 Admin Access (VPN required)

```text
Client device → wg0 handshake → UDP 51820 → WireGuard on VM
  → Device is now 10.0.0.x on the VPN
  → Browser → cockpit.${DOMAIN}:443
  → Traefik checks: source IP in 10.0.0.0/24?            ✓
  → Traefik forwardAuth → Authelia
      → Authenticated session exists?                    ✓ → pass through
      → No session → Authelia login page
          → Username + password                          ✓
          → TOTP code                                    ✓
          → Session established → redirect to original URL
  → Cockpit at 127.0.0.1:9090 (proxy auth header trusted; no second login)
```

If the source IP check fails (device not on VPN), Traefik returns `403` before Authelia is even consulted.

### 3.3 HTTP → HTTPS Redirect

All HTTP (port 80) traffic is permanently redirected to HTTPS by the Traefik `web` entrypoint redirect rule. No plaintext traffic reaches any backend.

## 4. Access Model & Methodology

### 4.1 The Challenge

Admin services (Dashboard, Metrics, Cockpit) need to be accessible from a fixed location with a known static IP, and also from arbitrary locations such as hotel WiFi, client offices, and mobile hotspots.

### 4.2 WireGuard-First, Always

The correct methodology is to route **all admin access through WireGuard**, regardless of source IP. This is not a compromise for remote access — it is the stronger security posture in every scenario.

| Concern                            | How it is handled                                                                                               |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Unknown source IP when travelling  | WireGuard authenticates by cryptographic key, not IP. Any device with a valid peer key can connect from any IP. |
| Untrusted network (hotel, café)    | WireGuard encrypts all traffic end-to-end. The local network sees only encrypted UDP packets.                   |
| Attacker probing port 51820        | WireGuard is silent to unauthenticated probes. Without the correct key, the port appears closed.                |
| Admin services exposed to internet | They are not. Traefik's `ipAllowList` blocks all non-VPN source IPs at the router level.                        |

### 4.3 Static IP Considerations

A static home or office IP is **not used as a security mechanism** in this stack. It is irrelevant to the access model. WireGuard is connected from any location the same way. Security derives from cryptographic keys, not from ISP IP assignment.

IP allowlisting on port 51820 creates operational risk — locking out administrators when an ISP reassigns an IP or when access is needed from an unplanned location — for no meaningful security gain.

### 4.4 Client Device Strategy

Register one WireGuard peer per device. Sharing peer configurations between devices means that revoking a lost device requires reconfiguring all devices that share it.

| Device  | Peer Name      | Keep-Alive | Notes                              |
| ------- | -------------- | ---------- | ---------------------------------- |
| Desktop | `peer-desktop` | not needed | Stays on fixed network             |
| Laptop  | `peer-laptop`  | 25s        | Travels; keep-alive helps with NAT |
| Phone   | `peer-phone`   | 25s        | Useful as mobile hotspot fallback  |

### 4.5 Ports Blocked on Some Networks

Some corporate firewalls and hotels block outbound UDP on non-standard ports. If port 51820 is blocked:

#### Option A — Change the WireGuard Port

Update `INIT_PORT` in `/data/containers/wg-easy/env` and the corresponding firewalld rule to UDP 443 or 53, then restart the service. Note this only takes effect on first start if the database does not yet exist; on an existing deployment, the port must be changed via the wg-easy UI or by resetting the database. Most firewalls pass UDP 443 or 53.

#### Option B — Phone Hotspot (Recommended Fallback)

Connect the laptop through a phone mobile hotspot. The phone's WireGuard peer routes all traffic through the VPN, and the laptop tunnels through the hotspot. No server-side reconfiguration needed.

## 5. Prerequisites & Provisioning Checklist

All of the following must exist before the instance is launched. Cloud-init cannot create them.

### 5.1 OCI Infrastructure

- [ ] **VCN and Subnet** — configured with Security List or NSG rules per section 5.2
- [ ] **Compute Instance** — Oracle Linux 9, any shape (AMD or ARM; the template handles both architectures)
- [ ] **Block Volume** — attached as paravirtualized; 50 GB minimum for logs and container data
- [ ] **Instance Principal** — the instance's dynamic group must have an IAM policy granting `read secret-family` on the Vault compartment (see section 7.1)
- [ ] **Vault** — OCI Vault (free tier sufficient) with three secrets created (see section 7)
- [ ] **Cloudflare** — DNS zone managed by Cloudflare; API token with `Zone → DNS → Edit` permission scoped to the specific zone

### 5.2 OCI Security List / NSG Rules (Ingress)

| Port  | Protocol | Source    | Purpose                                       |
| ----- | -------- | --------- | --------------------------------------------- |
| 80    | TCP      | 0.0.0.0/0 | HTTP (redirected to HTTPS by Traefik)         |
| 443   | TCP      | 0.0.0.0/0 | HTTPS (Traefik)                               |
| 51820 | UDP      | 0.0.0.0/0 | WireGuard VPN                                 |
| 22    | TCP      | Admin IP  | SSH (initial setup and emergency access only) |

> **SSH hardening:** Oracle Linux 9 OCI images disable password authentication by default. Verify before exposing port 22: `sudo grep PasswordAuthentication /etc/ssh/sshd_config` should return `PasswordAuthentication no`. If not, set it and restart sshd. **Close port 22 after the first WireGuard peer is added.** All ongoing management uses Cockpit over VPN. Emergency shell access is available without port 22 via OCI Bastion Service or OCI Console Connection.

## 6. Template Variables & Deployment

`cloud-config.example.yaml` uses `${VARIABLE}` syntax for site-specific values. The file must be processed with `envsubst` before use as instance user data. All other `${...}` references in the file are shell variables inside `runcmd` blocks and must remain unsubstituted.

### 6.1 Variable Reference

| Variable              | Description                                             | Example                       |
| --------------------- | ------------------------------------------------------- | ----------------------------- |
| `${DOMAIN}`           | Base domain for all subdomains                          | `example.com`                 |
| `${ACME_EMAIL}`       | Email for Let's Encrypt expiry notices                  | `ops@example.com`             |
| `${ADMIN_EMAIL}`      | Authelia admin user email                               | `admin@example.com`           |
| `${CF_SECRET_OCID}`   | OCID of the Cloudflare token secret in OCI Vault        | `ocid1.vaultsecret.oc1..xxxx` |
| `${AUTH_SECRET_OCID}` | OCID of the Authelia admin password secret in OCI Vault | `ocid1.vaultsecret.oc1..yyyy` |
| `${WG_SECRET_OCID}`   | OCID of the wg-easy admin password secret in OCI Vault  | `ocid1.vaultsecret.oc1..zzzz` |

The following subdomains are derived automatically from `${DOMAIN}`:

- `auth.${DOMAIN}` — Authelia SSO portal
- `traefik.${DOMAIN}` — Traefik dashboard
- `metrics.${DOMAIN}` — Prometheus metrics
- `cockpit.${DOMAIN}` — Cockpit OS console
- `wg.${DOMAIN}` — wg-easy WireGuard management

### 6.2 Generating the Deployment File

Create a `.env` file (never commit this to version control):

```bash
DOMAIN=example.com
ACME_EMAIL=ops@example.com
ADMIN_EMAIL=admin@example.com
CF_SECRET_OCID=ocid1.vaultsecret.oc1..xxxx
AUTH_SECRET_OCID=ocid1.vaultsecret.oc1..yyyy
WG_SECRET_OCID=ocid1.vaultsecret.oc1..zzzz
```

Run `envsubst`, passing only the six template variables explicitly to avoid substituting shell variable references in `runcmd` blocks:

```bash
export $(cat .env | xargs)

envsubst '${DOMAIN} ${ACME_EMAIL} ${ADMIN_EMAIL} ${CF_SECRET_OCID} ${AUTH_SECRET_OCID} ${WG_SECRET_OCID}' \
  < cloud-config.example.yaml > cloud-config.yaml
```

The output `cloud-config.yaml` is the file to paste into the OCI Console **User data** field, or pass via the OCI CLI:

```bash
oci compute instance launch \
  --user-data-file cloud-config.yaml \
  ... # other flags
```

### 6.3 Running cloud-init Manually

To run cloud-init on an already-provisioned instance (for testing or re-running after a failure):

```bash
# Check current status and logs
cloud-init status --long
sudo cat /var/log/cloud-init-output.log

# Reset and re-run
sudo cloud-init clean --logs
sudo cloud-init init
sudo cloud-init modules --mode=config
sudo cloud-init modules --mode=final
```

> `cloud-config.example.yaml` and its `runcmd` blocks are written to be idempotent. Re-running will not reformat the block volume, duplicate `fstab` entries, or overwrite existing Authelia or wg-easy data.

## 7. OCI Vault — Creating Secrets

The cloud-init script fetches three secrets from OCI Vault at first boot using Instance Principal authentication. No credentials are embedded in the template.

### 7.1 IAM Policy

Create a dynamic group for the instance, then create a policy:

```
# Dynamic Group — match by compartment or instance OCID
matching_rule = "instance.compartment.id = '<compartment-ocid>'"

# Policy — in root or relevant compartment
Allow dynamic-group <dynamic-group-name> to read secret-family in compartment <compartment-name>
```

### 7.2 Secret 1 — Cloudflare API Token

This token is used by Traefik to complete DNS-01 ACME challenges for TLS certificate issuance.

#### In Cloudflare

1. Go to **My Profile → API Tokens → Create Token → Create Custom Token**
2. Set permission: `Zone → DNS → Edit`
3. Set Zone Resources: `Include → Specific zone → <zone name>`
4. Optionally restrict to the instance public IP under **IP Address Filtering**
5. Copy the generated token — it is shown only once

#### In OCI Vault

1. Go to **Security → Vault → Secrets → Create Secret**
2. Name: `traefik-cloudflare-token`
3. Secret content: the Cloudflare token value
4. Copy the secret **OCID** — this is the value for `${CF_SECRET_OCID}`

### 7.3 Secret 2 — Authelia Admin Password

This is the password for the initial Authelia admin user. Authelia stores hashed credentials in its SQLite database on the block volume after first setup. This secret is only used during instance bootstrapping.

#### In OCI Vault

1. Go to **Security → Vault → Secrets → Create Secret**
2. Name: `authelia-admin-password`
3. Secret content: the chosen password in plain text (Authelia hashes it on first run)
4. Copy the secret **OCID** — this is the value for `${AUTH_SECRET_OCID}`

> The Authelia admin user is independent of the OS `opc` user and Cockpit's PAM authentication.

### 7.4 Secret 3 — wg-easy Admin Password

This is the password for the wg-easy web UI admin account. It is only processed during the first start of the container — after that, the unattended setup is disabled. This secret is only used during instance bootstrapping.

#### In OCI Vault

1. Go to **Security → Vault → Secrets → Create Secret**
2. Name: `wg-easy-admin-password`
3. Secret content: the chosen password in plain text
4. Copy the secret **OCID** — this is the value for `${WG_SECRET_OCID}`

> After initial setup is complete, the `INIT_USERNAME` and `INIT_PASSWORD` variables are no longer processed. The credentials are stored in wg-easy's SQLite database on the block volume. The secret in Vault is only needed on redeployment to bootstrap a fresh instance.

### 7.5 Verifying Secret Access After Boot

```bash
# Confirm Instance Principal authentication is working
oci secrets secret-bundle get \
  --secret-id <CF_SECRET_OCID value> \
  --query "data.secretBundleContent.content" \
  --raw-output | base64 -d
# Should print the Cloudflare token
```

## 8. DNS Configuration

All DNS records must exist in Cloudflare before cloud-init runs. Traefik will attempt ACME DNS-01 challenges immediately on first start.

### 8.1 Required Records

| Name                | Type | Value              | Proxy                     |
| ------------------- | ---- | ------------------ | ------------------------- |
| `traefik.${DOMAIN}` | A    | Instance public IP | **DNS Only** (grey cloud) |
| `metrics.${DOMAIN}` | A    | Instance public IP | **DNS Only** (grey cloud) |
| `cockpit.${DOMAIN}` | A    | Instance public IP | **DNS Only** (grey cloud) |
| `auth.${DOMAIN}`    | A    | Instance public IP | **DNS Only** (grey cloud) |
| `wg.${DOMAIN}`      | A    | Instance public IP | **DNS Only** (grey cloud) |
| `${DOMAIN}`         | A    | Instance public IP | Orange or grey cloud      |
| `*.${DOMAIN}`       | A    | Instance public IP | **DNS Only** (grey cloud) |

> **Why DNS Only (grey cloud)?** Traefik terminates TLS directly. Enabling Cloudflare proxying on admin subdomains causes Cloudflare's IPs to appear as the request source, bypassing the `ipAllowList` VPN check. Admin subdomains must always be unproxied.

> **Wildcard record:** A `*.${DOMAIN}` record means new services receive DNS resolution automatically without adding individual records. After a VM replacement, only the A record IP values need updating.

## 9. Block Volume — Persistent Storage Layout

The block volume survives VM termination and reattaches to new instances. This is the foundation of the immutable infrastructure pattern. Everything stateful lives here.

### 9.1 Block Device Path

The cloud-init script detects the block device automatically, probing in this order: `/dev/oracleoci/oraclevdb`, `/dev/sdb`, `/dev/vdb`. The default for OCI paravirtualized volumes is `/dev/oracleoci/oraclevdb`, but the path can vary depending on how the volume was attached or the instance shape. The first detected path is used — no manual configuration is needed.

The volume is mounted by UUID in `/etc/fstab`. If the device path changes between reboots, the mount remains stable.

### 9.2 Directory Structure

```text
/data/                       ← block volume mount point
├── traefik/
│   └── letsencrypt/         ← acme.json (TLS certificates)
├── authelia/
│   ├── config/              ← Authelia configuration files
│   ├── db/                  ← SQLite database (users, sessions, TOTP secrets)
│   └── logs/                ← Authelia logs
├── apps/                    ← application deployment manifests (see app-integration-guide.md)
├── containers/
│   ├── wg-easy/             ← WireGuard keys and peer config (managed by wg-easy)
│   └── <app-name>/          ← per-app data directories
└── logs/
    └── traefik/             ← Traefik access logs
```

### 9.3 Symlinks from OS Paths to /data

Cloud-init creates the following symlinks so services write to the block volume transparently:

```text
/etc/traefik/letsencrypt  →  /data/traefik/letsencrypt
/var/log/traefik          →  /data/logs/traefik
```

Authelia and wg-easy bind-mount their data directories directly from `/data/authelia/` and `/data/containers/wg-easy/` at container start — no symlinks needed.

### 9.4 What Persists Across VM Replacement

When the instance is terminated and a new one provisioned with the same block volume attached:

1. Cloud-init detects the existing filesystem (`blkid` finds `TYPE=xfs`) and skips formatting
2. WireGuard reads the existing private key from `/data/containers/wg-easy/` — no peer reconfiguration needed
3. Traefik reads the existing `acme.json` — no new certificate issuance needed
4. Authelia reads its existing SQLite database — user accounts, TOTP secrets, and sessions persist

The only things that reset are the OS itself, the Traefik binary (re-downloaded), and container images (re-pulled).

## 10. WireGuard — Peer Management via wg-easy

WireGuard is managed entirely by wg-easy. The server private key is generated by wg-easy on first start and stored in `/data/containers/wg-easy/`. Peer management — adding, revoking, and downloading client configurations — is done through the wg-easy web UI at `https://wg.${DOMAIN}`.

### 10.1 Bootstrap: Adding the First Peer

The wg-easy UI is behind the VPN, which creates a bootstrapping requirement: to access wg-easy, a WireGuard connection is needed, but a WireGuard peer must be added first. Resolve this via an SSH local port forward while port 22 is still open:

```bash
# Forward local port 51821 to wg-easy on the instance
ssh -L 51821:127.0.0.1:51821 opc@<instance-public-ip>
```

Open `http://localhost:51821` in a browser. This connects directly to wg-easy, bypassing Traefik and the VPN restriction. Add the first peer, download the client config or scan the QR code, connect WireGuard, verify access to `https://wg.${DOMAIN}`, then close port 22.

After confirming login works, remove the `INIT_USERNAME` and `INIT_PASSWORD` lines from `/data/containers/wg-easy/env` to prevent credential exposure, then restart the service:

```bash
sudo sed -i '/^INIT_USERNAME=/d;/^INIT_PASSWORD=/d' /data/containers/wg-easy/env
sudo systemctl restart wg-easy.service
```

### 10.2 Adding Peers

1. Connect to the VPN
2. Open `https://wg.${DOMAIN}` (authenticated via Authelia)
3. Click **New Client**, enter a name, and confirm
4. Download the client config file or scan the QR code
5. Import into the WireGuard app on the target device

wg-easy assigns IPs sequentially from `10.0.0.2`. The server always holds `10.0.0.1`.

### 10.3 Revoking a Peer

1. Open `https://wg.${DOMAIN}`
2. Locate the peer and click **Delete**

The peer is removed immediately from the running WireGuard interface. No reboot or service restart is required.

### 10.4 Client Configuration Notes

wg-easy generates client configs with `AllowedIPs = 0.0.0.0/0, ::/0` (full tunnel) by default. This is the correct setting for admin access — it ensures traffic to admin subdomains (which resolve to the VM's public IP, not the VPN IP) routes through the tunnel and passes the `ipAllowList` check.

Split-tunnel mode (`AllowedIPs = 10.0.0.0/24`) will not work for admin subdomains unless `/etc/hosts` overrides are added on the client, mapping each admin subdomain to `10.0.0.1`.

### 10.5 Getting the Server Public Key

The server public key is displayed in the wg-easy UI under **Admin Panel**. It can also be read directly from the running WireGuard interface on the instance:

```bash
sudo wg show wg0 public-key
```

## 11. Post-Deployment Verification

Run these checks after cloud-init completes (typically 5–10 minutes after instance boot).

### 11.1 Automated Verification

The `verify-stack.sh` script runs all checks in sequence and produces a pass/fail summary. It covers boot volume expansion, cloud-init status, block volume mount, symlinks, service health, TLS certificates, WireGuard, SELinux, journal persistence, and firewall rules.

```bash
sudo ./verify-stack.sh
```

Exit code `0` means all checks passed. Exit code `1` means one or more checks failed — review the output for specifics.

### 11.2 Investigating Failures

If the script reports failures, use these commands to dig deeper:

```bash
# Cloud-init full output
sudo cat /var/log/cloud-init-output.log

# Individual service logs
sudo journalctl -u traefik.service -n 50
sudo journalctl -u authelia.service -n 50
sudo journalctl -u wg-easy.service -n 50

# SELinux denials (if Traefik AVC check failed)
sudo ausearch -m avc -ts recent | grep traefik
# Apply a local policy to resolve:
sudo ausearch -m avc -ts recent | audit2allow -M traefik-local
sudo semodule -i traefik-local.pp
```

> Certificate issuance can take 1–3 minutes on first boot. If `acme.json` remains small after 5 minutes, verify that the Cloudflare token secret is correct and that all DNS records exist.

### 11.3 WireGuard Connectivity

`verify-stack.sh` checks the server side only. After adding the first peer (see section 10.1), verify end-to-end connectivity from the client device:

```bash
# Connect WireGuard (Linux client)
sudo wg-quick up wg0

# Ping the server VPN IP
ping 10.0.0.1

# Check the peer handshake on the server
sudo wg show
# "latest handshake" should show a recent timestamp
```

### 11.4 Admin Service Access

With WireGuard connected, open each admin URL in a browser. Each should redirect to the Authelia login page and grant access after successful authentication:

- `https://traefik.${DOMAIN}` → Authelia login → Traefik dashboard
- `https://metrics.${DOMAIN}/metrics` → Authelia login → Prometheus metrics output
- `https://cockpit.${DOMAIN}` → Authelia login → Cockpit OS console
- `https://wg.${DOMAIN}` → Authelia login → wg-easy peer management

Without WireGuard connected, all admin URLs should return `403 Forbidden` with no login prompt.

## 12. Adding Podman Container Services

Application containers are managed using **Podman Quadlet** — the native systemd-integrated container management system built into Podman. Quadlet replaces manual `podman run` commands and `podman generate systemd` with declarative `.container` unit files that systemd processes directly. Each service also requires a Traefik route config file.

`podman-compose` is intentionally not used. It exists solely for Docker Compose compatibility and adds no value in a Podman-native stack. Quadlet is the correct tool.

### 12.1 Two Files Per Service

Every new application service requires exactly two files:

```text
/etc/containers/systemd/<app>.container   ← Quadlet unit (container definition)
/etc/traefik/config/<app>.yaml            ← Traefik route (HTTP routing)
```

Traefik hot-reloads `.yaml` files from `/etc/traefik/config/` within seconds. Quadlet units are picked up by systemd on the next `systemctl daemon-reload`.

### 12.2 Quadlet Container File

Place the following in `/etc/containers/systemd/myapp.container`:

```ini
[Unit]
Description=My Application
After=local-fs.target network-online.target
Requires=local-fs.target

[Container]
Image=myapp-image:latest
PublishPort=127.0.0.1:8080:8080
Volume=/data/containers/myapp:/app/data:Z
Environment=NODE_ENV=production

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
```

The `:Z` flag on the volume is required on SELinux-enforcing systems — it sets the correct SELinux label on the bind-mounted directory. Without it, the container cannot read or write the mounted path.

Activate the container:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now myapp
```

Quadlet generates the systemd unit automatically from the `.container` file. No `podman run` or `podman generate systemd` needed.

### 12.3 Traefik Route File

Place the following in `/etc/traefik/config/myapp.yaml`:

```yaml
http:
  routers:
    myapp:
      rule: "Host(`app.example.com`)"
      entryPoints:
        - websecure
      service: myapp-svc
      tls:
        certResolver: cloudflare
      # Add admin-chain middleware here for VPN-restricted services

  services:
    myapp-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8080"
```

Traefik picks up the file immediately. No restart required.

### 12.4 Persistent Container Data

All container data must live under `/data/containers/<app-name>/` to survive VM replacement. The volume path in the Quadlet file handles this — `/data/containers/myapp` in the example above.

Create the directory before starting the container:

```bash
sudo mkdir -p /data/containers/myapp
```

### 12.5 Deploy Script

A parameterised script can generate both files from arguments, eliminating manual templating. See `deploy-service.sh` in the repository for a script that takes service name, image, internal port, and domain as arguments and creates both the Quadlet `.container` file and the Traefik `.yaml` config.

## 13. Maintenance & Operations

### 13.1 Certificate Renewal

Renewal is automatic. Traefik handles Let's Encrypt renewal via Cloudflare DNS-01 at least 30 days before expiry.

To force renewal (for example, after changing domains):

```bash
sudo systemctl stop traefik
sudo rm /data/traefik/letsencrypt/acme.json
sudo systemctl start traefik
# New acme.json is created on start; certificates issued within minutes
```

### 13.2 Updating Traefik

```bash
TRAEFIK_VERSION="v3.x.y"
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

curl -fsSL "https://github.com/traefik/traefik/releases/download/${TRAEFIK_VERSION}/traefik_${TRAEFIK_VERSION}_linux_${ARCH}.tar.gz" \
  | sudo tar -xz -C /usr/local/bin/ traefik

sudo systemctl restart traefik
traefik version
```

### 13.3 WireGuard Updates

```bash
sudo dnf update wireguard-tools
```

WireGuard is in-kernel on OL9 (UEK7). The kernel module is updated with the kernel package:

```bash
sudo dnf update kernel-uek
sudo reboot
```

### 13.4 Log Rotation

Traefik access logs are rotated automatically via `/etc/logrotate.d/traefik`: daily, 14-day retention, compressed. Systemd journal logs are persistent (written to `/var/log/journal/`) and managed by journald's `SystemMaxUse` setting.

```bash
journalctl --disk-usage
```

### 13.5 Rotating Secrets

#### Cloudflare Token

1. Create a new token in Cloudflare
2. Update the secret value in OCI Vault (create a new secret version)
3. Update the running instance:

```bash
NEW_TOKEN=$(oci secrets secret-bundle get \
  --secret-id <CF_SECRET_OCID value> \
  --query "data.secretBundleContent.content" \
  --raw-output | base64 -d)
echo "CF_DNS_API_TOKEN=$NEW_TOKEN" | sudo tee /etc/traefik/env
sudo chmod 600 /etc/traefik/env
sudo chown traefik:traefik /etc/traefik/env
sudo systemctl restart traefik
```

#### Authelia Admin Password

1. Update the secret in OCI Vault
2. Generate a new hash and update the users database:

```bash
NEW_PASS=$(oci secrets secret-bundle get \
  --secret-id <AUTH_SECRET_OCID value> \
  --query "data.secretBundleContent.content" \
  --raw-output | base64 -d)
podman exec authelia authelia crypto hash generate argon2 --password "$NEW_PASS"
# Update the resulting hash in /data/authelia/config/users_database.yaml
```

No Traefik restart needed.

### 13.6 VM Replacement (Disposable Instance Workflow)

1. Note the block volume OCID and attachment details
2. Terminate the instance (the block volume detaches but is not deleted)
3. Provision a new OCI instance with the same shape and OS, `cloud-config.yaml` (generated from `cloud-config.example.yaml`) as user data, and the existing block volume attached as paravirtualized
4. Update the A records in Cloudflare to the new instance public IP
5. Cloud-init runs, detects existing block volume data, and skips all destructive steps
6. Services start with all persistent state intact

Total downtime: the time between old instance termination and new instance reaching `cloud-init status: done` — typically 5–8 minutes.

### 13.7 Block Volume Backups (Restic)

The block volume holds all persistent state. If it is lost or corrupted, WireGuard keys, TLS certificates, the Authelia database, container data, and logs are all lost. The VM replacement workflow does not protect against this. Backups are essential.

[Restic](https://restic.net) is the recommended tool: a single static binary, deduplicating, encrypted at rest, and compatible with OCI Object Storage via its S3-compatible API.

#### Setup

1. Create an OCI Object Storage bucket for backups (private)
2. Create an OCI Customer Secret Key (S3-compatible credentials) under the user profile
3. Store the secret key in OCI Vault as a fourth secret, following the same pattern as section 7

#### Backup Commands

```bash
export AWS_ACCESS_KEY_ID="<oci-customer-secret-key-id>"
export AWS_SECRET_ACCESS_KEY="<oci-customer-secret-key>"
export RESTIC_PASSWORD="<restic-repository-password>"
export RESTIC_REPOSITORY="s3:https://<namespace>.compat.objectstorage.<region>.oraclecloud.com/<bucket>"

# Initialise the repository (first time only)
restic init

# Run a backup
restic backup /data

# List snapshots
restic snapshots

# Restore latest snapshot
restic restore latest --target /data
```

#### Automate with a Systemd Timer

Store Restic credentials in `/etc/restic/env` (mode `0600`), fetched from OCI Vault at boot following the same pattern as `/etc/traefik/env`.

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

### 13.8 Infrastructure as Code (Terraform)

`cloud-config.example.yaml` automates the OS layer, but the OCI resources it depends on (VCN, subnets, security lists, block volume, Vault, instance) are currently provisioned manually. Codifying these with Terraform completes the immutable infrastructure picture — the entire stack can be rebuilt with a single command.

A minimal Terraform layout for this stack:

```text
terraform/
├── main.tf       # Provider config, VCN, subnet, security list
├── compute.tf    # Instance definition, cloud-init user_data reference
├── storage.tf    # Block volume and attachment
├── vault.tf      # Vault and secret definitions (values injected via Terraform variables)
├── dns.tf        # Cloudflare provider and DNS records
└── variables.tf  # Domain, region, compartment OCID, etc.
```

The Cloudflare Terraform provider can manage DNS records automatically, so updating the instance IP after a VM replacement becomes part of `terraform apply` rather than a manual step. Terraform state should be stored remotely in OCI Object Storage configured as a Terraform backend.

## 14. Security Reference

### 14.1 Traefik Systemd Hardening Summary

| Directive                 | Value                       | Effect                                                             |
| ------------------------- | --------------------------- | ------------------------------------------------------------------ |
| `NoNewPrivileges`         | true                        | Process cannot gain additional capabilities                        |
| `ProtectSystem`           | strict                      | `/usr`, `/boot`, `/etc` read-only except explicit `ReadWritePaths` |
| `ProtectHome`             | true                        | `/home`, `/root`, `/run/user` inaccessible                         |
| `PrivateTmp`              | true                        | Private `/tmp` — container escape mitigation                       |
| `CapabilityBoundingSet`   | `CAP_NET_BIND_SERVICE` only | Cannot access raw sockets or modify kernel                         |
| `AmbientCapabilities`     | `CAP_NET_BIND_SERVICE`      | Allows binding ports 80 and 443 as non-root user                   |
| `RestrictAddressFamilies` | `AF_INET AF_INET6 AF_UNIX`  | No raw sockets, no netlink                                         |
| `SystemCallFilter`        | `@system-service`           | Blocks syscalls not needed by normal services                      |

### 14.2 What Protects Each Surface

| Surface            | Protection Layers                                                                    |
| ------------------ | ------------------------------------------------------------------------------------ |
| Traefik Dashboard  | VPN subnet (`ipAllowList`) + Authelia (password + TOTP)                              |
| Prometheus Metrics | VPN subnet (`ipAllowList`) + Authelia (password only)                                |
| Cockpit            | VPN subnet (`ipAllowList`) + Authelia (password + TOTP); Cockpit trusts proxy header |
| wg-easy            | VPN subnet (`ipAllowList`) + Authelia (password + TOTP)                              |
| Public app routes  | TLS (Let's Encrypt) + per-app authentication                                         |
| SSH                | Firewall restricted to admin IP; closed after first peer is added                    |
| WireGuard          | Curve25519 key exchange; silent to unauthenticated probes                            |
| Secrets at rest    | OCI Vault (HSM-backed); never written to cloud-init or environment in plaintext      |
| Secrets in transit | Instance Principal (no stored credentials); Vault API over TLS                       |
| Filesystem         | SELinux enforcing; Traefik runs as dedicated system user with minimal write paths    |
| Kernel audit       | `auditd` running; logs to persistent journal                                         |

### 14.3 Threat Model: What This Stack Does Not Protect Against

- **Compromised Cloudflare account:** An attacker with access to the Cloudflare account can issue certificates and redirect DNS.
- **Compromised OCI account:** An attacker with OCI console access can read Vault secrets or connect to the instance directly.
- **Peer key theft:** A stolen WireGuard peer private key grants VPN access until the peer is revoked in wg-easy.
- **Traefik vulnerabilities:** Monitor `https://github.com/traefik/traefik/security/advisories` and keep Traefik updated.
- **Container breakout:** Authelia and wg-easy run as rootful Podman containers (system-level service units). Application containers added via `deploy-service.sh` also run rootful by default. Keep container images updated and avoid `--privileged` or unnecessary capabilities.
