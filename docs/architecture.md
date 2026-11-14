---
name: "Architecture"
description: |
  Project purpose, goals, principles, constraints, system architecture, security model, risks, and decision index for the OCI secure stack.
status: draft
version: 1.1
updated: 2026-11-13
---

# Architecture

This is the single design record for the project. It states what the system is, what it must achieve, and how it is structured. Deployment evidence and current status are tracked in `docs/process/`.

## Purpose

Provide a reproducible, documented, single-VM Oracle Linux 9 admin environment on Oracle Cloud Infrastructure. The environment hosts a small number of self-managed services. It exposes a minimal public surface and protects administrative access with WireGuard and Authelia MFA. It keeps all persistent state on a separate block volume so the VM can be replaced.

## Primary goal

A clean OCI instance must provision from the tracked cloud-init configuration and reach a verified, operable state without manual repair. After provisioning:

- Only Traefik on TCP 80 and 443 and WireGuard on UDP 51820 are reachable from the internet.
- Every administrative surface is reachable only over the WireGuard VPN and requires Authelia MFA.
- Traefik issues TLS certificates automatically.
- All state required to survive replacement resides on the block volume.
- A replacement instance attached to the same block volume resumes service without reconfiguration.

## Outcomes

1. **Reproducible provisioning.** A tracked configuration produces the same working stack on a clean instance.
2. **Controlled administrative access.** No administrative path bypasses the VPN or the MFA gate.
3. **Durable state.** Certificates, user accounts, VPN peers, and application data survive VM replacement.
4. **Application hosting.** Additional services can be added without modifying the core stack.
5. **Operational clarity.** An operator can deploy, verify, diagnose, and replace the stack from documented procedures.

## Success criteria

| ID  | Criterion                                                                                                                     |
| --- | ----------------------------------------------------------------------------------------------------------------------------- |
| S1  | A clean instance reaches `cloud-init status: done` with no unhandled errors                                                   |
| S2  | The block volume is mounted at `/data`, recorded by UUID, and survives reboot                                                 |
| S3  | Traefik serves valid TLS certificates for every configured hostname                                                           |
| S4  | Administrative URLs return 403 without the VPN and require password plus TOTP over the VPN                                    |
| S5  | No administrative service is reachable directly, bypassing Traefik and Authelia                                               |
| S6  | The verification procedure passes with recorded evidence                                                                      |
| S7  | A replacement instance attached to the same block volume preserves certificates, users, sessions, peers, and application data |
| S8  | A new operator can deploy and verify the stack from tracked documentation alone                                               |

## Non-goals

- Hosting application source code in this repository.
- Multi-tenant operation or large user directories.
- High availability, clustering, or horizontal scaling.
- A Kubernetes platform.
- Support for operating systems other than Oracle Linux 9 in v1.
- A public SaaS offering.
- A general-purpose platform for arbitrary workloads.

## Constraints

- Oracle Cloud Infrastructure, Oracle Linux 9, AMD or ARM.
- One compute instance in v1.
- A separately attached block volume for persistent state.
- Cloudflare manages the DNS zone.
- OCI Vault stores runtime secrets; no secret is committed to the repository.
- The host is treated as immutable: no in-place manual configuration is authoritative.
- The public network surface is limited to TCP 80, TCP 443, and UDP 51820.
- The target is the Oracle Cloud Free Tier Always Free services or the lowest practical paid tier.

When trade-offs conflict, decide in this order:

1. Security and correctness over convenience.
2. Proven behaviour over documented intent.
3. Reproducibility over in-place configuration.
4. Simplicity over feature breadth.
5. Documentation after verification, not before it.

## Principles

### P1. Reproducibility

The stack must be rebuildable from tracked artifacts. Nothing required for operation may exist only in a console, a shell history, or a manually edited file on the host.

Implication: every durable setting belongs in a tracked configuration or in a documented provisioning step.

### P2. Immutable infrastructure

The compute instance is disposable. All persistent state lives on the block volume at `/data`. The host is replaced, not patched in place.

Implication: a missing or unmounted block volume is a fatal condition, not a warning.

### P3. Least privilege

Services run under dedicated identities with only the capabilities they require. The default administrator account is not used as a service account.

Implication: each service declares its user, its writable paths, and its capabilities.

### P4. Minimal public surface

Only Traefik and WireGuard are publicly reachable. Administrative surfaces are reachable only over the VPN and only after MFA. A service that does not need public access does not get it.

Implication: no administrative port is opened directly, even to the VPN subnet, when Traefik can proxy it.

### P5. Secrets are external

OCI Vault stores runtime secrets. Cloud-init fetches them with Instance Principal authentication. Templates, manifests, and repository files contain no secret values.

Implication: a failed secret fetch aborts provisioning. It does not continue with empty values.

### P6. Evidence over assertion

A claim about the system is valid only when an execution log, a test result, or a direct artifact supports it. Documentation describes proven behaviour.

Implication: findings are closed after verification, not after a code change.

### P7. Infrastructure-only repository

This repository contains infrastructure, configuration, and documentation. Application source code belongs in its own repositories.

Implication: application integration is defined by a contract, not by vendored code.

## Context and scope

The stack is a single OCI compute instance with one attached block volume. Cloud-init provisions the operating system, installs packages, configures services, and starts containers. OCI Vault supplies runtime secrets. Cloudflare supplies DNS and the ACME DNS-01 challenge.

The design targets a single operator or a small group. It is not a managed platform, a multi-tenant service, or a high-availability system. The VM is replaceable; the block volume is the durable asset.

## System architecture

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
│  10.0.0.x      │   │  (forwardAuth)  │     │   Containers   │
│  address only  │   └────────┬────────┘     └────────────────┘
└────────────────┘            │
                ┌─────────────┼─────────────┐
                │             │             │
           ┌────▼────┐  ┌─────▼─────┐  ┌────▼─────┐
           │ Cockpit │  │ Dashboard │  │ wg-easy  │
           │  :9090  │  │  Metrics  │  │ (Podman) │
           └─────────┘  └───────────┘  └──────────┘
```

WireGuard and Traefik are parallel services. WireGuard provides the encrypted tunnel that puts a client device on the `10.0.0.0/24` VPN subnet. Traefik's `ipAllowList` middleware enforces that all admin-facing routes are reachable only from that subnet. For those routes, Traefik delegates authentication to Authelia via `forwardAuth`, providing a single login with TOTP across all admin services. Application and public services go through Traefik without the VPN restriction or Authelia.

### Component roles

| Component         | Role                                   | Exposed port     | Authentication    |
| ----------------- | -------------------------------------- | ---------------- | ----------------- |
| Traefik           | Edge router, TLS termination, routing  | 80, 443 public   | None              |
| WireGuard         | VPN tunnel for admin access            | 51820/UDP public | Peer public key   |
| Authelia          | SSO and MFA gateway for admin routes   | Loopback 9091    | None              |
| Traefik dashboard | Router, middleware, service inspection | Loopback only    | SSH tunnel        |
| Traefik metrics   | Prometheus metrics endpoint            | Loopback only    | SSH tunnel        |
| Cockpit           | Full OS web console                    | Through Traefik  | Authelia plus PAM |
| wg-easy           | WireGuard peer management UI           | Through Traefik  | Authelia          |
| Podman containers | Application workloads                  | Per application  | Per application   |

Authelia runs as a rootless Quadlet user unit. wg-easy runs as a rootful Quadlet system unit inside a user namespace with only `NET_ADMIN` and `NET_RAW`. Traefik runs as a native systemd service. See ADR-002, ADR-008, and ADR-009.

The exposure model is defined in ADR-001. The design binds the dashboard and raw metrics to loopback. The design binds Cockpit to loopback and proxies it through Traefik behind Authelia and PAM. The current implementation does not yet satisfy this model; findings F6, F8, and F9 record the gaps. Any future management-plane exposure requires a new ADR.

### Traffic flows

Public application traffic:

```text
Browser → app.<domain>:443
  → Traefik (TLS termination via Cloudflare DNS-01)
  → Podman container on 127.0.0.1:<port>
  → Response
```

No VPN and no IP restriction. Authentication is configured per service in its Traefik dynamic configuration.

Administrative access:

```text
Client → wg0 handshake → UDP 51820 → WireGuard on the VM
  → Client receives 10.0.0.x on the VPN
  → Browser → cockpit.<domain>:443
  → Traefik checks source IP in 10.0.0.0/24
  → Traefik forwardAuth → Authelia
  → Password and TOTP
  → Cockpit at 127.0.0.1:9090
```

If the source IP check fails, Traefik returns `403` before Authelia is consulted.

All HTTP traffic on port 80 is permanently redirected to HTTPS. No plaintext traffic reaches a backend.

### Access model

All administrative access goes through WireGuard, regardless of source IP. This is the stronger security posture in every scenario.

| Concern                            | Handling                                                                                                        |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Unknown source IP when travelling  | WireGuard authenticates by cryptographic key, not IP. Any device with a valid peer key can connect from any IP. |
| Untrusted network                  | WireGuard encrypts all traffic end to end. The local network sees only encrypted UDP packets.                   |
| Attacker probing port 51820        | WireGuard is silent to unauthenticated probes. Without the correct key, the port appears closed.                |
| Admin services exposed to internet | They are not. Traefik `ipAllowList` blocks all non-VPN source IPs at the router level.                          |

The design does not use a static home or office IP as a security mechanism. IP allowlisting on port 51820 creates operational risk without meaningful security gain.

Register one WireGuard peer per device. Sharing peer configurations means that revoking a lost device requires reconfiguring every device that shares it.

Corporate firewalls and hotels can block outbound UDP on non-standard ports. If port 51820 is blocked, change the WireGuard port in `/data/containers/wg-easy/env` and the firewall rule. Alternatively, use a phone hotspot as the fallback. The hotspot option requires no server-side change.

## Security model

### Surface protection

| Surface            | Protection layers                                                                   |
| ------------------ | ----------------------------------------------------------------------------------- |
| Traefik dashboard  | Loopback only, accessed through an SSH tunnel                                       |
| Traefik metrics    | Loopback only, accessed through an SSH tunnel                                       |
| Cockpit            | VPN subnet, Authelia password plus TOTP, then Cockpit PAM                           |
| wg-easy            | VPN subnet, Authelia password plus TOTP                                             |
| Public app routes  | TLS via Let's Encrypt, plus per-application authentication                          |
| SSH                | Firewall restricted to the admin IP; closed after the first peer is added           |
| WireGuard          | Curve25519 key exchange; silent to unauthenticated probes                           |
| Secrets at rest    | OCI Vault, HSM-backed; never written to cloud-init or environment in plaintext      |
| Secrets in transit | Instance Principal, no stored credentials; Vault API over TLS                       |
| Filesystem         | SELinux enforcing; Traefik runs as a dedicated system user with minimal write paths |
| Kernel audit       | `auditd` running; logs to the persistent journal                                    |

### Threat model

This stack does not protect against:

- A compromised Cloudflare account. An attacker can issue certificates and redirect DNS.
- A compromised OCI account. An attacker can read Vault secrets or connect to the instance directly.
- Peer key theft. A stolen WireGuard private key grants VPN access until the peer is revoked.
- Traefik vulnerabilities. Monitor the Traefik security advisories and keep Traefik updated.
- Container breakout. Authelia runs rootless. wg-easy runs rootful inside a user namespace with only `NET_ADMIN` and `NET_RAW`. Application containers follow ADR-005. These isolation boundaries are unverified until a deployment test. Keep images updated. Avoid privileged containers.

## Quality and acceptance

Version 1.0 is complete when:

- Every success criterion S1 to S8 has recorded evidence.
- The deployment checklist in `docs/process/acceptance-criteria.md` passes.
- The VM replacement drill passes.
- The backup and restore scope is either implemented and tested or explicitly deferred.
- A new operator completes deployment using only tracked documentation.
- The maintainer tags the release and updates the changelog.

## Risks and technical debt

Open findings and technical debt are tracked in `docs/process/issue-log.md`. The principal current risks are:

- The first deployment may fail at Authelia because of rootless ownership, subordinate ID allocation, or SELinux relabel.
- A failed block volume mount may silently produce an ephemeral deployment.
- The implemented admin exposure model may bypass the stated security model.
- The refactor may proceed before behaviour is proven.
- Version pins may be unavailable or incompatible.

These risks are not confirmed runtime failures until a deployment test produces evidence.

## Decision index

| ID      | Decision                             | Status |
| ------- | ------------------------------------ | ------ |
| ADR-001 | Management plane exposure model      | Draft  |
| ADR-002 | Authelia runtime and file ownership  | Draft  |
| ADR-003 | Metrics architecture                 | Draft  |
| ADR-004 | Persistence and mount failure policy | Draft  |
| ADR-005 | Application container contract       | Draft  |
| ADR-006 | Backup and recovery scope            | Draft  |
| ADR-007 | OCI provisioning method              | Draft  |
| ADR-008 | Traefik runtime                      | Draft  |
| ADR-009 | Infrastructure container runtime     | Draft  |

ADR-006 and ADR-007 remain draft. ADR-009 is decided in content and remains draft until committed and confirmed.

## Related documents

- Decision records: `docs/decisions/`
- Deployment tutorial: `docs/guides/getting-started.md`
- Operations runbook: `docs/guides/operations.md`
- Application integration: `docs/guides/adding-apps.md`
- Infrastructure reference: `docs/reference/infrastructure.md`
- Traefik reference: `docs/reference/traefik.md`
- Application manifest reference: `docs/reference/application-manifest.md`
- Process record: `docs/process/process-index.md`
- Current status: `docs/process/project-status.md`
- Issue log: `docs/process/issue-log.md`
- Delivery plan: `docs/process/delivery-plan.md`
- Acceptance criteria: `docs/process/acceptance-criteria.md`
