---
name: "Project Goals"
description: |
  Defines the project purpose, primary goal, outcomes, success criteria, non-goals, constraints, priorities, and definition of done for the OCI secure stack.
status: draft
version: 1.0
updated: 2026-11-12
---

# Project Goals

This document is normative once confirmed.

## Purpose

Provide a reproducible, documented, single-VM Oracle Linux 9 admin stack on Oracle Cloud Infrastructure for hosting a small number of self-managed services. The stack exposes a minimal public surface, protects administrative access with WireGuard and Authelia MFA, and keeps all persistent state on a separate block volume so the VM can be replaced.

## Primary goal

A clean OCI instance must provision from the tracked cloud-init configuration and reach a verified, operable state without manual repair. After provisioning:

- Only Traefik on TCP 80 and 443 and WireGuard on UDP 51820 are reachable from the internet.
- Every administrative surface is reachable only over the WireGuard VPN and requires Authelia MFA.
- TLS certificates are issued automatically.
- All state required to survive replacement is stored on the block volume.
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
- The target budget is OCI Always Free or the lowest practical paid tier.

## Priorities

When trade-offs conflict, decide in this order:

1. **Security and correctness** over convenience.
2. **Proven behaviour** over documented intent.
3. **Reproducibility** over in-place configuration.
4. **Simplicity** over feature breadth.
5. **Documentation after verification**, not before it.

## Definition of done

Version 1.0 is complete when:

- Every success criterion S1 to S8 has recorded evidence.
- The deployment checklist passes.
- The VM replacement drill passes.
- The backup and restore scope is either implemented and tested or explicitly deferred.
- A new operator completes deployment using only tracked documentation.
- The release is tagged and the changelog is current.

## Related documents

- Project principles: `docs/principles.md`
- Strategic decisions: `docs/decisions/`
- Process tracking: `docs/process/`
- Goals audit and evidence trail: `docs/process/goals-audit.md`
