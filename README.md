# oracle-cloud-init: An Opinionated Admin Stack

A production-ready, cloud-init-based provisioning template for Oracle Cloud Infrastructure (OCI) that deploys a hardened admin stack on Oracle Linux 9.

## What This Stack Provides

A single VM instance provisioned from this template runs the following services:

| Service                 | Role                                                                             |
| ----------------------- | -------------------------------------------------------------------------------- |
| **Traefik v3**          | Edge router, TLS termination (Let's Encrypt via Cloudflare DNS-01), HTTP routing |
| **Authelia**            | SSO and MFA gateway (password + TOTP) for all admin services                     |
| **WireGuard (wg-easy)** | VPN for admin access — all admin routes restricted to VPN subnet                 |
| **Cockpit**             | Full OS web console, accessible over VPN only                                    |
| **Podman (Quadlet)**    | Container runtime for all services and applications                              |
| **PCP**                 | Performance Co-Pilot for host-level metrics                                      |

All state (certificates, user accounts, WireGuard keys, container data) lives on a separately attached block volume — the VM itself is disposable and replaceable in under 10 minutes.

## Architecture

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
│    10.0.0.x    │   │  (forwardAuth)  │     │   Containers   │
│  address only  │   └────────┬────────┘     └────────────────┘
└────────────────┘            │
                ┌─────────────┼─────────────┐
                │             │             │
           ┌────▼────┐  ┌─────▼─────┐  ┌────▼─────┐
           │ Cockpit │  │ Dashboard │  │ wg-easy  │
           │  :9090  │  │  Metrics  │  │ (Podman) │
           └─────────┘  └───────────┘  └──────────┘
```

## Repository Contents

| File                        | Purpose                                                        |
| --------------------------- | -------------------------------------------------------------- |
| `cloud-config.example.yaml` | Cloud-init template — process with `envsubst` before deploying |
| `.env.example`              | Variable template — copy to `.env` and fill in values          |
| `stack-guide.md`            | Full architecture, setup, and operations guide                 |
| `app-integration-guide.md`  | Guidelines for deploying applications into the stack           |
| `deploy-service.sh`         | Script to deploy a new Podman container service                |
| `verify-stack.sh`           | Post-deployment verification script                            |
| `testing-guide.md`          | Strategy for testing the stack and individual components       |

## Quick Start

1. **Read the prerequisites** in `stack-guide.md` Section 5 — OCI infrastructure, Vault secrets, and DNS records must exist before deploying.

2. **Configure variables:**

   ```bash
   cp .env.example .env
   # Edit .env with your domain, email, and OCI Vault secret OCIDs
   ```

3. **Generate the deployment file:**

   ```bash
   export $(cat .env | xargs)
   envsubst '${DOMAIN} ${ACME_EMAIL} ${ADMIN_EMAIL} ${CF_SECRET_OCID} ${AUTH_SECRET_OCID} ${WG_SECRET_OCID}' \
     < cloud-config.example.yaml > cloud-config.yaml
   ```

4. **Deploy:** Paste `cloud-config.yaml` into the OCI Console User Data field when creating an instance.

5. **Verify:** After 5–10 minutes, run `sudo ./verify-stack.sh` on the instance.

See `stack-guide.md` for the complete deployment walkthrough.

## Security Model

- All admin services (Dashboard, Metrics, Cockpit, wg-easy) are accessible **only over VPN** — the `ipAllowList` middleware blocks all non-VPN source IPs before Authelia is even consulted
- Authelia provides unified SSO with TOTP for all admin routes
- TLS certificates issued automatically via Let's Encrypt DNS-01 challenge using the Cloudflare API
- Secrets stored in OCI Vault, fetched at boot via Instance Principal — no credentials in the template
- SELinux enforcing mode; Traefik runs as a dedicated system user with minimal capabilities
- Block volume mounted at `/data/` — all persistent state survives VM replacement

## Deploying Applications

See `app-integration-guide.md` for detailed guidance on deploying containerised applications into the stack, including authentication patterns, persistent storage conventions, and the automated deployment manifest system.

## Requirements

- Oracle Cloud Infrastructure account
- OCI Vault (free tier sufficient)
- Cloudflare account managing the target DNS zone
- Oracle Linux 9 instance (AMD or ARM — the template handles both)
- Separate block volume (50 GB minimum)

## License

MIT License — see [LICENSE](LICENSE).

## Security Vulnerabilities

See [SECURITY.md](SECURITY.md) for the security disclosure policy.
