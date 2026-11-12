---
name: "Project Principles"
description: |
  Defines the project principles for reproducibility, immutable infrastructure, least privilege, minimal public surface, secret handling, evidence, and repository scope.
status: draft
version: 1.0
updated: 2026-11-12
---

# Project Principles

These principles are normative once confirmed.

Principles govern design and trade-offs. Goals state what the project must achieve; principles state how decisions are made when several valid options exist.

## P1. Reproducibility

The stack must be rebuildable from tracked artifacts. Nothing required for operation may exist only in a console, a shell history, or a manually edited file on the host.

Implication: every durable setting belongs in a tracked configuration or in a documented provisioning step.

## P2. Immutable infrastructure

The compute instance is disposable. All persistent state lives on the block volume at `/data`. The host is replaced, not patched in place.

Implication: a missing or unmounted block volume is a fatal condition, not a warning.

## P3. Least privilege

Services run under dedicated identities with only the capabilities they require. The default administrator account is not used as a service account.

Implication: each service declares its user, its writable paths, and its capabilities.

## P4. Minimal public surface

Only Traefik and WireGuard are publicly reachable. Administrative surfaces are reachable only over the VPN and only after MFA. A service that does not need public access does not get it.

Implication: no administrative port is opened directly, even to the VPN subnet, when Traefik can proxy it.

## P5. Secrets are external

Runtime secrets are stored in OCI Vault and fetched with Instance Principal authentication. Templates, manifests, and repository files contain no secret values.

Implication: a failed secret fetch aborts provisioning. It does not continue with empty values.

## P6. Evidence over assertion

A claim about the system is valid only when supported by an execution log, a test result, or a direct artifact. Documentation describes proven behaviour.

Implication: findings are closed after verification, not after a code change.

## P7. Infrastructure-only repository

This repository contains infrastructure, configuration, and documentation. Application source code belongs in its own repositories.

Implication: application integration is defined by a contract, not by vendored code.
