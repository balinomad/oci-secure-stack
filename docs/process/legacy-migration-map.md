---
name: "Legacy Content Migration Map"
description: |
  Mapping from legacy documents to target project documentation, used to preserve content during migration.
status: active
version: 1.0
updated: 2026-11-12
---

# Legacy Content Migration Map

Purpose: preserve the useful content of the legacy documents while the new documentation tree is populated. This is a work-tracking artifact. Update it as sections are migrated.

Target paths may not exist yet. Do not delete a legacy document until every section is mapped and the replacement has been verified.

| Legacy Document              | Section                                             | Target Destination                                                 |
| ---------------------------- | --------------------------------------------------- | ------------------------------------------------------------------ |
| **stack-guide.md**           | 1-4 (Architecture, Flows, Access)                   | `docs/architecture.md`                                             |
|                              | 5-8 (Prerequisites, Variables, Vault, DNS)          | `docs/specifications/infrastructure.md`, `docs/getting-started.md` |
|                              | 9, 13.7 (Block Volume, Restic)                      | `docs/specifications/storage.md`, `docs/guides/maintenance.md`     |
|                              | 10 (WireGuard/wg-easy)                              | `docs/components/wireguard.md`                                     |
|                              | 11 (Post-Deployment)                                | `docs/guides/getting-started.md`, `docs/guides/troubleshooting.md` |
|                              | 12, 15 (Adding Services, Manifests)                 | `docs/guides/adding-apps.md`, `docs/components/podman.md`          |
|                              | 13 (Maintenance, Updates, VM Replace)               | `docs/guides/maintenance.md`                                       |
|                              | 14 (Security Reference, Threat Model)               | `docs/architecture.md`, `docs/components/traefik.md`               |
| **traefik-guide.md**         | 1-3, 16, 19 (Scope, Design, App Contract)           | `docs/components/traefik.md`, `docs/architecture.md`               |
|                              | 4-15, 17-18, 20-21 (Install, Config, Maint)         | `docs/components/traefik.md`                                       |
| **app-integration-guide.md** | 1-3, 8, 12, 14 (Quadlet, Storage, Network, SELinux) | `docs/components/podman.md`, `docs/guides/adding-apps.md`          |
|                              | 4 (Building Images)                                 | `docs/guides/adding-apps.md`                                       |
|                              | 5-7 (Traefik, Headers, AuthN/AuthZ)                 | `docs/guides/adding-apps.md`, `docs/guides/security-headers.md`    |
|                              | 9-11, 15 (Secrets, Logging, Backup, Manifests)      | `docs/guides/adding-apps.md`, `docs/specifications/storage.md`     |
|                              | 16-17 (Workflow, Checklist)                         | `docs/guides/adding-apps.md`                                       |
| **testing-guide.md**         | 1-3 (Philosophy, Pre-deploy, Incremental)           | `docs/guides/troubleshooting.md`, `docs/guides/testing.md`         |
|                              | 4-7 (Components, Full Stack, Failures)              | `docs/guides/troubleshooting.md`                                   |
