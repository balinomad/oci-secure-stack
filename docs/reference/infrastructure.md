---
name: "Infrastructure Reference"
description: |
  Exact template variables, OCI network rules, DNS records, Vault secrets, persistent storage layout, and reserved ports for the stack.
status: draft
version: 1.0
updated: 2026-11-12
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

Derived hostnames:

- `auth.${DOMAIN}`
- `cockpit.${DOMAIN}`
- `wg.${DOMAIN}`

The Traefik dashboard and metrics are loopback-only and have no DNS records or Traefik routes.

## 2. OCI network rules

Ingress:

| Port  | Protocol | Source    | Purpose                                      |
| ----- | -------- | --------- | -------------------------------------------- |
| 80    | TCP      | 0.0.0.0/0 | HTTP, redirected to HTTPS by Traefik         |
| 443   | TCP      | 0.0.0.0/0 | HTTPS through Traefik                        |
| 51820 | UDP      | 0.0.0.0/0 | WireGuard VPN                                |
| 22    | TCP      | Admin IP  | SSH, initial setup and emergency access only |

Do not expose 8080, 8082, 9090, 9091, or 51821 publicly.

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

| Secret name                | Purpose                         | Variable              |
| -------------------------- | ------------------------------- | --------------------- |
| `traefik-cloudflare-token` | ACME DNS-01 challenge           | `${CF_SECRET_OCID}`   |
| `authelia-admin-password`  | Initial Authelia admin password | `${AUTH_SECRET_OCID}` |
| `wg-easy-admin-password`   | Initial wg-easy admin password  | `${WG_SECRET_OCID}`   |

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
│   └── logs/                # Authelia logs
├── apps/                    # application deployment manifests
├── containers/
│   ├── wg-easy/             # WireGuard keys and peer data
│   └── <app-name>/          # per-application data
└── logs/
    └── traefik/             # Traefik access and error logs
```

Symlinks:

```text
/etc/traefik/letsencrypt  ->  /data/traefik/letsencrypt
/var/log/traefik          ->  /data/logs/traefik
```

Authelia and wg-easy bind-mount their data directly from `/data/`.

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
| 8080  | Traefik dashboard and API, loopback  |
| 8082  | Traefik Prometheus metrics, loopback |
| 9090  | Cockpit                              |
| 9091  | Authelia                             |
| 51820 | WireGuard, UDP                       |
| 51821 | wg-easy management UI                |

## Related documents

- Design: `docs/architecture.md`
- Deployment: `docs/guides/getting-started.md`
- Traefik reference: `docs/reference/traefik.md`
- Application manifest reference: `docs/reference/application-manifest.md`
