---
name: "Component Scope and Research Findings"
description: |
  Technical scope, configuration boundaries, and flagged challenges for Cockpit, PCP metrics, Authelia, Traefik, and cross-component constraints. Research evidence for the ADR set.
status: draft
version: 1.0
updated: 2026-11-12
---

# Component Scope & Research Findings (Phase 2)

This document is research evidence, not a specification. Normative decisions are recorded in `docs/decisions/`. The metrics routing proposal in Section 2 is superseded by ADR-001 and ADR-003.

## 1. Cockpit (OS Web Console)

**Role:** Provides a web-based UI for OS-level management (storage, logs, services, terminal) on Oracle Linux 9.

### Scope & Configuration

- **Installation:** Native OL9 packages (`cockpit`, `cockpit-storaged`, `cockpit-podman`). Managed via `cockpit.socket` (systemd), binding to `127.0.0.1:9090`.
- **Traefik Proxying:** Cockpit relies heavily on WebSockets for the terminal and real-time metric streaming. The Traefik route must be configured to handle WebSocket upgrades (`Upgrade` and `Connection` headers).
- **Configuration File:** `/etc/cockpit/cockpit.conf` must be configured to accept the proxied `Origin` and `Forwarded` headers to prevent Cockpit from dropping the connection.

### Additional Findings

- **Authentication Trust:** Cockpit must perform its own PAM authentication. It does not natively support header-based authentication (e.g., trusting `Remote-User` from Traefik) without complex, fragile PAM modules.
- **Access Model:** Security correctness dictates that Authelia provides the network/SSO gate (VPN + TOTP), and Cockpit prompts for the OS `opc`/`root` password for the actual session. Double-login is the secure, correct default.
- **Implication:** Legacy statements implying "no second login" or "trusts proxy header" are incorrect and must be removed.

## 2. Prometheus & PCP (Host Metrics)

**Role:** Collects and exposes host-level metrics (CPU, RAM, Disk I/O, Network) and Podman container metrics.

### Scope & Configuration

- **PCP (Performance Co-Pilot):** Native OL9 packages (`pcp`, `pcp-system-tools`, `pcp-zeroconf`). Runs via `pmcd` (daemon) and `pmlogger` (historical logging).
- **Metrics Exporter:** Use PCP's native `pmproxy` (or `pcp-export-prometheus2`), which exposes a Prometheus-compatible `/metrics` endpoint on a local port (e.g., `127.0.0.1:44322`).
- **Podman Metrics:** Enable the Podman socket or use `podman` PMDA (Performance Metrics Domain Agent) so PCP can scrape container stats.
- **Traefik Route:** Expose the PCP Prometheus endpoint via `metrics.${DOMAIN}` using the `admin-chain` middleware (VPN + Authelia).

### Additional Findings

- **Metric Sensitivity:** Metrics are sensitive data (hostnames, traffic patterns, error rates). They must not be exposed publicly or protected by password-only authentication.
- **Scope Constraint:** Running a full Prometheus server (scraping, TSDB, Alertmanager) is redundant and resource-heavy for an Always Free instance. The stack will use a **PCP-native export** model.
- **Access Model:** If a metrics interface is exposed via Traefik, it must enforce TOTP via Authelia (`admin-chain`), not just VPN or simple password protection.
- **Metrics Multiplexing:** The stack generates two distinct metric streams: Host/OS metrics (via PCP on `127.0.0.1:44322`) and Traefik router metrics (via Traefik internal on `127.0.0.1:8082`).
- **Routing Decision:** If a unified `metrics.${DOMAIN}` is required, Traefik must be configured to route specific paths (e.g., `/host` to PCP, `/traefik` to internal) or expose them on separate subdomains. Both streams are highly sensitive and require the `admin-chain` (VPN + TOTP).

## 3. Authelia (SSO & MFA Gateway)

**Role:** Provides ForwardAuth for Traefik, enforcing TOTP and session management for all admin routes.

### Scope & Configuration

- **Runtime:** Podman container via Quadlet. Binds to `127.0.0.1:9091`.
- **Configuration (`configuration.yml`):**
  - **Authentication Backend:** File-based (`users_database.yaml`) using Argon2id hashing.
  - **Storage:** SQLite database (`/data/authelia/db/storage.sqlite`) for TOTP secrets, 2FA devices, and encryption keys.
  - **Session:** Stored in SQLite or memory, with the secret key injected from OCI Vault at boot.
  - **Access Control Rules:** Explicitly mapping `*.${DOMAIN}` (admin routes) to `two_factor` policy.
- **Traefik Integration:** `forwardAuth` middleware pointing to `http://127.0.0.1:9091/api/verify`.

### Additional Findings

- **Privilege Level:** Security correctness dictates running Authelia as a **rootless** Podman container (or dedicated non-root systemd service) to minimize blast radius. Rootful operation is rejected as the default.
- **Secret Persistence:** Operational correctness requires that JWT, session, and storage encryption keys persist on the block volume (`/data/authelia/`) across VM replacements. They must not be ephemeral.
- **Bootstrap:** `cloud-init` must generate these secrets on first boot if they do not exist, ensuring the instance is functional immediately but state is persistent.
- **Rootless Bootstrapping:** Because `cloud-init` executes as root, deploying Authelia as a rootless Podman container requires explicit provisioning steps: creating the dedicated user, enabling systemd lingering (`loginctl enable-linger`), and placing the Quadlet unit in the correct user-level or system-level drop-in directory to ensure it starts on boot without an active user session.

## 4. Traefik (Edge Router)

**Role:** TLS termination, HTTP routing, and middleware enforcement.

### Scope & Configuration

- **Runtime:** Native binary managed by a heavily sandboxed systemd unit. Containerization (Podman) is rejected for the edge router to minimize the attack surface and eliminate rootless port-forwarding complexity for ports 80/443.
- **Binding:** Public traffic on 80/443. Dashboard (8080) and Metrics (8082) strictly bound to `127.0.0.1`.

### Additional Findings

- **Management Plane Exposure:** The Traefik dashboard and API must never be exposed via Traefik routes, even behind Authelia. Security correctness dictates they remain strictly localhost-only, accessible solely via SSH local port forwarding (`ssh -L 8080:127.0.0.1:8080`).
- **Supersedes:** Any legacy suggestion of exposing `traefik.${DOMAIN}` publicly or through the `admin-chain`.

## 5. Architectural Constraints

The following constraints apply to all components in this stack.

- **Ephemeral OS, Persistent Data:** The VM root filesystem is ephemeral and disposable. All persistent state must reside on the block volume mounted at `/data/`. All services and configurations must be reproducible via `cloud-init`.
- **Service Ownership:** Services must not run as the default SSH user (`opc`). Dedicated, non-login system users must be created for each service to enforce least privilege and isolation.

## 6. Superseded Statements

The following statements found in legacy planning documents are technically incorrect or insecure and are superseded by the findings in this document.

| Legacy Statement                                 | Correction                                                                                        |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| "Cockpit trusts proxy header; no second login"   | Cockpit does not support this securely out-of-the-box. Double login (Authelia + PAM) is required. |
| "Prometheus Metrics: Authelia password only"     | Metrics are sensitive. TOTP (`admin-chain`) is required if exposed.                               |
| "Rootful Podman container via Quadlet" (default) | Rootless operation is preferred for Authelia to reduce privilege escalation risks.                |
| Public exposure of raw metrics endpoints         | Metrics endpoints must be internal or strictly gated by VPN and MFA.                              |
| Services running as the default `opc` user       | Services must run as dedicated non-login system users.                                            |

## Decision Records

- [ADR-001: Management Plane Exposure Model](../decisions/001-exposure-model.md)
- [ADR-002: Authelia Runtime and File Ownership](../decisions/002-authelia-runtime.md)
- [ADR-003: Metrics Architecture](../decisions/003-metrics-architecture.md)
- [ADR-004: Persistence and Mount Failure Policy](../decisions/004-persistence.md)
- [ADR-005: Application Container Contract](../decisions/005-application-contract.md)
- [ADR-008: Traefik Runtime](../decisions/008-traefik-runtime.md)
