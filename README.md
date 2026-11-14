# oci-secure-stack

A cloud-init-based provisioning template for a single Oracle Linux 9 admin stack on Oracle Cloud Infrastructure. The design exposes only Traefik and WireGuard publicly. It keeps administrative surfaces behind WireGuard and Authelia and stores persistent state on a separate block volume.

The project was created with the Oracle Cloud Free Tier, specifically its Always Free services, as one target use case. Always Free services are not a requirement. The template also targets paid OCI shapes and larger block volumes.

The stack is designed but not yet proven in a deployment. See [docs/process/project-status.md](docs/process/project-status.md) for the current state and evidence.

## What the stack provides

| Service                 | Role                                                                             |
| ----------------------- | -------------------------------------------------------------------------------- |
| **Traefik v3**          | Edge router, TLS termination (Let's Encrypt via Cloudflare DNS-01), HTTP routing |
| **Authelia**            | SSO and MFA gateway (password plus TOTP) for admin services                      |
| **WireGuard (wg-easy)** | VPN for admin access; admin routes restricted to the VPN subnet                  |
| **Cockpit**             | OS web console, reachable through Traefik behind Authelia and PAM                |
| **Podman (Quadlet)**    | Container runtime for infrastructure and application services                    |
| **PCP**                 | Performance Co-Pilot for host, container, and OpenMetrics collection            |
| **Grafana**             | Local live monitoring UI over PCP, loopback-only, live profile                  |
| **Valkey**              | PCP history store, loopback-only, history profile                               |

All state, including certificates, user accounts, WireGuard keys, and container data, lives on a separately attached block volume. The VM is treated as disposable.

## Documentation

| Reader need            | Document                                                                                                                                                 |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Understand the design  | [docs/architecture.md](docs/architecture.md)                                                                                                             |
| Read the decisions     | [docs/decisions/decision-index.md](docs/decisions/decision-index.md)                                                                                     |
| Deploy the stack       | [docs/guides/getting-started.md](docs/guides/getting-started.md)                                                                                         |
| Operate and recover it | [docs/guides/operations.md](docs/guides/operations.md)                                                                                                   |
| Add an application     | [docs/guides/adding-apps.md](docs/guides/adding-apps.md)                                                                                                 |
| Look up exact values   | [infrastructure](docs/reference/infrastructure.md), [Traefik](docs/reference/traefik.md), [application manifest](docs/reference/application-manifest.md) |
| Track project status   | [docs/process/process-index.md](docs/process/process-index.md)                                                                                           |

## Quick start

1. Create the OCI network, block volume, Vault secrets, and DNS records. Follow [docs/guides/getting-started.md](docs/guides/getting-started.md).
2. Copy `.env.example` to `.env` and fill in the eight values. Set `MONITORING_PROFILE` to `live`, `history`, or `none`.
3. Render the deployment file:

   ```bash
   export $(cat .env | xargs)
   scripts/repo/render-config.sh \
     | envsubst '${DOMAIN} ${ACME_EMAIL} ${ADMIN_EMAIL} ${CF_SECRET_OCID} ${AUTH_SECRET_OCID} ${WG_SECRET_OCID} ${GRAFANA_SECRET_OCID} ${MONITORING_PROFILE}' \
     > cloud-config.yaml
   ```

4. Launch the instance with `cloud-config.yaml` as user data and attach the block volume.
5. After first boot, run `scripts/host/verify-stack.sh` as root from a repository checkout on the instance.

The complete sequence, including the first WireGuard peer bootstrap, is in [docs/guides/getting-started.md](docs/guides/getting-started.md).

## Security model

The design requires the following controls. The current implementation does not yet satisfy all of them; open gaps are recorded in [docs/process/issue-log.md](docs/process/issue-log.md).

- Only TCP 80, TCP 443, and UDP 51820 are publicly reachable.
- Administrative routes require a WireGuard peer and Authelia password plus TOTP. Traefik returns `403` to requests outside the VPN subnet before it consults authentication.
- The Traefik dashboard, Traefik metrics, PCP `pmproxy`, Grafana, and Valkey bind to loopback and do not have public routes.
- Traefik issues TLS certificates through Let's Encrypt DNS-01 with a Cloudflare token stored in OCI Vault.
- Cloud-init fetches secrets at boot with Instance Principal authentication. Contributors do not commit secrets to the repository.
- SELinux runs in enforcing mode. Traefik runs as a dedicated system user with minimal capabilities.
- Authelia runs rootless as a dedicated system user. wg-easy runs inside a user namespace with only `NET_ADMIN` and `NET_RAW`.

The full security model, threat model, and non-goals are in [docs/architecture.md](docs/architecture.md). Report vulnerabilities through [SECURITY.md](SECURITY.md).

## Requirements

- Oracle Cloud Infrastructure account
- OCI Vault
- Cloudflare account managing the target DNS zone
- Oracle Linux 9 instance, AMD or ARM
- Separate block volume, 50 GB minimum
- 4 GB RAM, 2 vCPU, and 2 GB free disk for the `live` monitoring profile
- 6 GB RAM, 2 vCPU, and 5 GB free disk for the `history` monitoring profile
- Workstation with `yq` v4 and `envsubst`

## Repository layout

| Path                                         | Purpose                                                       |
| -------------------------------------------- | ------------------------------------------------------------- |
| `infra/cloud-init/cloud-config.example.yaml` | Cloud-init template; render before deploying                  |
| `configs/`                                   | Component configuration sources and manifest                  |
| `scripts/repo/render-config.sh`              | Render component configuration into the cloud-config template |
| `.env.example`                               | Variable template; copy to `.env` and fill in values          |
| `scripts/host/deploy-service.sh`             | Deploy a new Podman container service                         |
| `scripts/host/deploy/07-monitoring.sh`       | Install or change the local monitoring profile                |
| `scripts/host/verify-stack.sh`               | Post-deployment verification                                  |
| `docs/`                                      | Design, decisions, guides, reference, and process records     |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Documentation conventions are in [docs/process/document-conventions.md](docs/process/document-conventions.md).

## License

MIT License. See [LICENSE](LICENSE).
