---
name: "Acceptance Criteria"
description: |
  Acceptance checklist for proving a deployment, covering prerequisites, boot, services, security, recovery, and release criteria.
status: active
version: 1.0
updated: 2026-11-12
---

# Acceptance Criteria

A deployment is complete only when every item is proven with evidence. Mark `Claimed` items as unproven until an execution log or test result exists. The success criteria are defined in `docs/architecture.md`.

Evidence source: command output, log excerpt, test screenshot, or a linked finding.

## 1. Prerequisites

| ID  | Criterion                                                                        | Evidence                               | Status      |
| --- | -------------------------------------------------------------------------------- | -------------------------------------- | ----------- |
| P1  | OCI VCN and subnet allow TCP 80, TCP 443, and UDP 51820                          | Security list or NSG export            | Claimed     |
| P2  | Dynamic group and IAM policy allow `read secret-family` in the Vault compartment | Policy export                          | Claimed     |
| P3  | Three Vault secrets exist with the expected names                                | `oci secrets secret-bundle get` output | Claimed     |
| P4  | All required DNS records exist and admin records are DNS-only                    | Cloudflare zone export                 | Claimed     |
| P5  | A block volume is attached and is empty or intentionally preserved               | OCI console, `lsblk`                   | Claimed     |
| P6  | A disposable test environment exists for phases D and E                          | Environment record                     | Not started |

## 2. Boot and persistence

| ID  | Criterion                                            | Evidence                        | Status  |
| --- | ---------------------------------------------------- | ------------------------------- | ------- |
| B1  | `cloud-init status` reports `done`                   | `cloud-init status --long`      | Claimed |
| B2  | The cloud-init output log has no unhandled errors    | Reviewed log                    | Claimed |
| B3  | `/data` is mounted from the block volume             | `findmnt /data`                 | Claimed |
| B4  | The fstab entry uses a UUID and survives reboot      | `cat /etc/fstab`, reboot test   | Claimed |
| B5  | Boot aborts safely when `/data` is absent or not XFS | Negative test                   | Claimed |
| B6  | Reboot preserves the mount and all service state     | Reboot test                     | Claimed |
| B7  | A second cloud-init run is idempotent                | Rerun test and state comparison | Claimed |

## 3. Services

| ID  | Criterion                                             | Evidence                                       | Status  |
| --- | ----------------------------------------------------- | ---------------------------------------------- | ------- |
| S1  | Traefik is active and listens on 80 and 443           | `systemctl`, `ss -lntp`                        | Claimed |
| S2  | HTTP redirects to HTTPS                               | `curl -I`                                      | Claimed |
| S3  | Certificates are issued for every configured hostname | `acme.json`, `openssl s_client`                | Claimed |
| S4  | Authelia starts and exposes its health endpoint       | `journalctl`, local `curl`                     | Claimed |
| S5  | Authelia login and TOTP succeed                       | Browser test                                   | Claimed |
| S6  | Authelia data persists across restart and replacement | Restart and replacement test                   | Claimed |
| S7  | wg-easy starts and serves its UI on localhost         | `systemctl`, local `curl`                      | Claimed |
| S8  | The first peer is created and the tunnel handshakes   | `podman exec wg-easy wg show`, `ping 10.0.0.1` | Claimed |
| S9  | Cockpit is active and reachable through Traefik       | Browser test                                   | Claimed |
| S10 | Cockpit WebSocket terminal works through Traefik      | Browser test                                   | Claimed |
| S11 | The chosen metrics endpoint returns data              | `curl`                                         | Claimed |
| S12 | PCP services are active, if PCP is in scope           | `systemctl`                                    | Claimed |

## 4. Security controls

| ID  | Criterion                                                              | Evidence                     | Status  |
| --- | ---------------------------------------------------------------------- | ---------------------------- | ------- |
| X1  | Admin URLs return 403 without VPN                                      | Client test without tunnel   | Claimed |
| X2  | Admin URLs require password and TOTP over VPN                          | Client test                  | Claimed |
| X3  | No admin surface bypasses Authelia, including direct ports             | Port scan from VPN           | Claimed |
| X4  | Dashboard and metrics follow the confirmed exposure decision           | Config review plus port scan | Claimed |
| X5  | Security headers are present on admin responses                        | `curl -I`                    | Claimed |
| X6  | SELinux is enforcing with no AVC denials                               | `getenforce`, `ausearch`     | Claimed |
| X7  | firewalld exposes only 80, 443, 51820/udp, and bootstrap SSH           | `firewall-cmd --list-all`    | Claimed |
| X8  | SSH is closed after the first peer is verified                         | OCI security list            | Claimed |
| X9  | Secrets are absent from templates, manifests, and world-readable files | Config review                | Claimed |
| X10 | Vault fetch failure prevents boot rather than degrading silently       | Negative test                | Claimed |

## 5. Disposability and recovery

| ID  | Criterion                                                              | Evidence                 | Status  |
| --- | ---------------------------------------------------------------------- | ------------------------ | ------- |
| R1  | A replacement instance attaches the existing block volume              | Replacement drill        | Claimed |
| R2  | Certificates survive replacement                                       | `acme.json`, TLS test    | Claimed |
| R3  | Authelia users and sessions survive replacement                        | Login test               | Claimed |
| R4  | WireGuard peers survive replacement                                    | Peer test                | Claimed |
| R5  | Application data survives replacement                                  | App test                 | Claimed |
| R6  | Restic backup completes and a restore succeeds, if in scope            | Backup log, restore test | Claimed |
| R7  | Rollback to the previous instance or snapshot is documented and tested | Runbook review           | Claimed |

## 6. Documentation and release

| ID  | Criterion                                                  | Evidence                                      | Status  |
| --- | ---------------------------------------------------------- | --------------------------------------------- | ------- |
| D1  | A new operator can deploy from tracked documentation alone | Fresh-read test                               | Claimed |
| D2  | Documentation matches tested behaviour                     | Cross-check                                   | Claimed |
| D3  | README claims are accurate and dated                       | Review                                        | Claimed |
| D4  | All documentation links resolve                            | `scripts/repo/audit-docs.sh` exits 0          | Proven  |
| D5  | A release tag and changelog exist                          | `git tag`, `CHANGELOG.md`                     | Claimed |
| D6  | Version pins are documented and verified                   | Release notes                                 | Claimed |

## Sign-off

| Field                      | Value |
| -------------------------- | ----- |
| Deployment date            |       |
| OCI region and shape       |       |
| Oracle Linux image version |       |
| Domain                     |       |
| Traefik version            |       |
| Authelia version           |       |
| wg-easy version            |       |
| Verified by                |       |
| Evidence location          |       |
