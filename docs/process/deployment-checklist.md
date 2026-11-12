---
name: "Deployment Acceptance Checklist"
description: |
  Acceptance checklist for proving a deployment, covering prerequisites, boot, services, security, recovery, and release criteria.
status: active
version: 1.0
updated: 2026-11-12
---

# Deployment Acceptance Checklist

A deployment is complete only when every item is proven with evidence. Mark `Claimed` items as unproven until an execution log or test result exists.

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

| ID  | Criterion                                            | Evidence                        | Status   |
| --- | ---------------------------------------------------- | ------------------------------- | -------- |
| B1  | `cloud-init status` reports `done`                   | `cloud-init status --long`      | Unproven |
| B2  | The cloud-init output log has no unhandled errors    | Reviewed log                    | Unproven |
| B3  | `/data` is mounted from the block volume             | `findmnt /data`                 | Unproven |
| B4  | The fstab entry uses a UUID and survives reboot      | `cat /etc/fstab`, reboot test   | Unproven |
| B5  | Boot aborts safely when `/data` is absent or not XFS | Negative test                   | Unproven |
| B6  | Reboot preserves the mount and all service state     | Reboot test                     | Unproven |
| B7  | A second cloud-init run is idempotent                | Rerun test and state comparison | Unproven |

## 3. Services

| ID  | Criterion                                             | Evidence                        | Status   |
| --- | ----------------------------------------------------- | ------------------------------- | -------- |
| S1  | Traefik is active and listens on 80 and 443           | `systemctl`, `ss -lntp`         | Unproven |
| S2  | HTTP redirects to HTTPS                               | `curl -I`                       | Unproven |
| S3  | Certificates are issued for every configured hostname | `acme.json`, `openssl s_client` | Unproven |
| S4  | Authelia starts and exposes its health endpoint       | `journalctl`, local `curl`      | Unproven |
| S5  | Authelia login and TOTP succeed                       | Browser test                    | Unproven |
| S6  | Authelia data persists across restart and replacement | Restart and replacement test    | Unproven |
| S7  | wg-easy starts and serves its UI on localhost         | `systemctl`, local `curl`       | Unproven |
| S8  | The first peer is created and the tunnel handshakes   | `wg show`, `ping 10.0.0.1`      | Unproven |
| S9  | Cockpit is active and reachable through Traefik       | Browser test                    | Unproven |
| S10 | Cockpit WebSocket terminal works through Traefik      | Browser test                    | Unproven |
| S11 | The chosen metrics endpoint returns data              | `curl`                          | Unproven |
| S12 | PCP services are active, if PCP is in scope           | `systemctl`                     | Unproven |

## 4. Security controls

| ID  | Criterion                                                              | Evidence                     | Status   |
| --- | ---------------------------------------------------------------------- | ---------------------------- | -------- |
| X1  | Admin URLs return 403 without VPN                                      | Client test without tunnel   | Unproven |
| X2  | Admin URLs require password and TOTP over VPN                          | Client test                  | Unproven |
| X3  | No admin surface bypasses Authelia, including direct ports             | Port scan from VPN           | Unproven |
| X4  | Dashboard and metrics follow the confirmed exposure decision           | Config review plus port scan | Unproven |
| X5  | Security headers are present on admin responses                        | `curl -I`                    | Unproven |
| X6  | SELinux is enforcing with no AVC denials                               | `getenforce`, `ausearch`     | Unproven |
| X7  | firewalld exposes only 80, 443, 51820/udp, and bootstrap SSH           | `firewall-cmd --list-all`    | Unproven |
| X8  | SSH is closed after the first peer is verified                         | OCI security list            | Unproven |
| X9  | Secrets are absent from templates, manifests, and world-readable files | Config review                | Unproven |
| X10 | Vault fetch failure prevents boot rather than degrading silently       | Negative test                | Unproven |

## 5. Disposability and recovery

| ID  | Criterion                                                              | Evidence                 | Status   |
| --- | ---------------------------------------------------------------------- | ------------------------ | -------- |
| R1  | A replacement instance attaches the existing block volume              | Replacement drill        | Unproven |
| R2  | Certificates survive replacement                                       | `acme.json`, TLS test    | Unproven |
| R3  | Authelia users and sessions survive replacement                        | Login test               | Unproven |
| R4  | WireGuard peers survive replacement                                    | Peer test                | Unproven |
| R5  | Application data survives replacement                                  | App test                 | Unproven |
| R6  | Restic backup completes and a restore succeeds, if in scope            | Backup log, restore test | Unproven |
| R7  | Rollback to the previous instance or snapshot is documented and tested | Runbook review           | Unproven |

## 6. Documentation and release

| ID  | Criterion                                                  | Evidence                  | Status   |
| --- | ---------------------------------------------------------- | ------------------------- | -------- |
| D1  | A new operator can deploy from tracked documentation alone | Fresh-read test           | Unproven |
| D2  | Documentation matches tested behaviour                     | Cross-check               | Unproven |
| D3  | README claims are accurate and dated                       | Review                    | Unproven |
| D4  | All documentation links resolve                            | Link check                | Unproven |
| D5  | A release tag and changelog exist                          | `git tag`, `CHANGELOG.md` | Unproven |
| D6  | Version pins are documented and verified                   | Release notes             | Unproven |

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
