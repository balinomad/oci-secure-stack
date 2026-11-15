---
name: "ADR-012: Runtime Secret Delivery"
description: |
  Decision to keep OCI Vault as the only durable secret store and deliver runtime secret values through ephemeral files or service credentials.
status: draft
version: 1.1
updated: 2026-11-15
---

# ADR-012: Runtime Secret Delivery

## Context

The stack reads secrets from OCI Vault at boot. Several services keep runtime copies under `/etc` or `/data`. `infra/host/deploy-service.sh` can write application environment values into a Quadlet unit and a deployment manifest. A persistent copy creates a second at-rest store and can enter backups.

## Affected paths

- `docs/architecture.md`
- `docs/guides/adding-apps.md`
- `docs/reference/application-manifest.md`
- `infra/cloud-init/cloud-config.template.yaml`
- `infra/host/deploy-service.sh`
- `infra/host/03-traefik.sh`
- `infra/host/04-authelia.sh`
- `infra/host/07-monitoring.sh`
- `infra/host/08-alerting.sh`
- `infra/configs/podman/authelia.container`
- `infra/configs/podman/wg-easy.container`
- `infra/configs/systemd/traefik.service`
- `infra/configs/systemd/grafana-server.service.d/env.conf`
- `infra/configs/systemd/stack-secrets-traefik.service`
- `infra/configs/systemd/stack-secrets-grafana.service`
- `infra/configs/systemd/stack-secrets-alerting.service`
- `infra/configs/systemd/stack-secrets.conf`
- `infra/runtime/secrets/materialize.sh`
- `infra/manifest.yaml`
- `infra/manifest.schema.json`
- `tools/validate-manifest.sh`
- `infra/host/verify-stack.sh`

## Current text or behavior

OCI Vault is the source for Vault-backed secrets. Phase 1 and Phase 2 make `infra/host/deploy-service.sh` write application values to `/run/apps/<name>/env` with mode `0600` and record OCIDs in the deployment manifest.

Phase 3 adds `/usr/local/libexec/stack-secret-env` and three oneshot units. The reference files `/etc/secure-stack/secret-refs/{traefik,grafana,alerting}.env` contain OCIDs only. The oneshot units write `/run/traefik/env`, `/run/monitoring/grafana/env`, and `/run/monitoring/alerting/env`. Traefik, Grafana, and the alerting units require their oneshot unit.

Authelia still generates its JWT, session, and storage encryption keys on first boot and persists them in `/data/authelia/env`. wg-easy still uses `/data/containers/wg-easy/env`. Phase 4 and D10 remain open.

## Contradiction

A persistent runtime copy is a second at-rest secret store. It can enter backups and outlive the Vault value. The application deployment path can also expose values in a world-readable manifest. This contradicts the requirement that OCI Vault is the only durable secret store.

## Options

1. Keep root-only persistent environment files under `/etc` and `/data`.
2. Move Vault-backed runtime values to `/run` or service credentials, and keep only OCI Vault as durable storage.
3. Give every application direct OCI Vault access with Instance Principal.
4. Keep the current deployment path and change only the manifest permissions.

## Consequences of each option

- Option 1: simple and survives reboot, but keeps a second at-rest copy and can enter backups.
- Option 2: removes the second at-rest copy. Boot and manifest replay must re-fetch. Some applications need a file-based or environment-variable adapter.
- Option 3: no runtime copy, but every application needs OCI SDK support and Instance Principal authorization.
- Option 4: fixes the world-readable manifest only. Persistent secret copies remain.

## Recommendation

Adopt option 2. Use `/run` for environment-only services. Use systemd credentials or Podman secrets where the service can read a file. Keep OCI Vault as the only durable store. Store only secret OCIDs or references in manifests. Exclude `/run` from backups.

## Decision

1. OCI Vault is the only durable secret store.
2. Vault-backed runtime values are fetched at boot or deployment into `/run` or a service credential.
3. Quadlet units use `EnvironmentFile=` or `Secret=`. They do not use `Environment=SECRET=value`.
4. `infra/host/deploy-service.sh` accepts `--secret-env KEY=OCID` and writes values only to `/run/apps/<name>/env` with mode `0600`.
5. Deployment manifests are mode `0600` and record secret OCIDs, not values.
6. The backup scope excludes `/run`.
7. The Authelia JWT, session, and storage encryption values move to OCI Vault before `/data/authelia/env` is removed. `PUID`, `PGID`, and `UMASK` remain non-secret runtime settings. The storage encryption key remains immutable for the database lifetime.
8. The wg-easy environment file remains persistent until a disposable test proves that `INIT_PASSWORD` is used only on first initialization.

## Consequences

- Boot and manifest replay must fetch Vault values before dependent services start.
- A Vault failure must block service start, not degrade to an empty value.
- Secret rotation requires a service restart and a Vault update. It does not require a manifest edit.
- The Authelia storage encryption key is a durable Vault value. Losing it makes the database unreadable.
- F11 remains `Needs verification` until a deployment test confirms the runtime path. X9 remains `Claimed` until the same test.
- Phase 3 is implemented but not proven. No deployment evidence exists for a reboot, a Vault failure, or a secret rotation.
- The wg-easy migration is blocked on the disposable test in `docs/process/delivery-plan.md` D10.

## Open questions

- Does wg-easy use `INIT_PASSWORD` only on first initialization? If yes, remove it after the first successful login and move the remaining settings to `/run/wg-easy/env`. If no, keep the file persistent as a recorded exception. No disposable host is available in the current environment, so D10 remains open.
- Do all application containers support file-based secrets, or do some require environment variables? `/run` environment files cover the latter.

## References

- `docs/architecture.md` section "Security model"
- `docs/guides/adding-apps.md` sections 2, 7, 8, 14, and 15
- `docs/reference/application-manifest.md`
- `docs/process/issue-log.md` F11
- `docs/process/acceptance-criteria.md` X9
- `docs/process/delivery-plan.md` D10
