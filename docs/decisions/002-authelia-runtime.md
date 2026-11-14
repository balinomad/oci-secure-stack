---
name: "ADR-002: Authelia Runtime and File Ownership"
description: |
  Decision to run Authelia as a rootless Podman container under a dedicated user with persistent state on the data volume.
status: draft
version: 1.2
updated: 2026-11-14
---

# ADR-002: Authelia Runtime and File Ownership

## Context

Authelia holds session keys, TOTP secrets, and the user database. Running it as root expands the blast radius. Finding F1 records an ownership mismatch between root-owned files and the user that the official image runs as. The official image starts as UID 0 when `PUID` and `PGID` are set, then drops privileges to that user.

## Affected paths

- `infra/cloud-init/cloud-config.template.yaml:426-485`
- `docs/process/issue-log.md` F1, F10

## Current text or behavior

The template starts Authelia as a plain unit and has a root-owned file ownership mismatch with the image user. The static conversion to a rootless Quadlet unit is applied but unproven.

## Contradiction

The design requires rootless execution under a dedicated user with `/data/authelia` owned by that user. The current template and file ownership do not prove that contract.

## Options

1. Keep the plain unit and root-owned files.
2. Run Authelia as a rootless Quadlet user unit under a dedicated `authelia` user with subordinate IDs and `/data/authelia` ownership.
3. Run Authelia as a rootful container with a dedicated user inside the container.

## Consequences of each option

- Option 1: the blast radius stays large. F1 and F10 remain open, and the ownership mismatch persists.
- Option 2: the blast radius is smaller. The deployment needs subordinate IDs, lingering, `:Z` relabel, and a deployment test.
- Option 3: port binding is simpler, but the container retains rootful host privileges. The rootless contract is not met.

## Recommendation

Adopt option 2.

## Decision

1. Run Authelia as a rootless Podman Quadlet user unit, not a plain `podman run` system unit.
2. Run it under a dedicated non-login system user named `authelia`, not `opc` and not `root`.
3. Allocate subordinate UID and GID range `400000-465535` to that user. The range must not overlap another service.
4. Enable systemd lingering for the user. Install the Quadlet unit under `/etc/containers/systemd/users/<authelia-uid>/authelia.container`.
5. Use `UserNS=keep-id` and set `PUID` and `PGID` to the service user UID and GID. Container root maps to a subordinate host UID; the Authelia process runs as the service user.
6. Store configuration, database, environment, and keys under `/data/authelia/`, owned by `authelia:authelia`, with directories at `0700`. Set the process umask to `0077` so new files are created at `0600`.
7. Bind the container to `127.0.0.1:9091`.
8. Persist JWT and session secrets across VM replacement.
9. Generate missing secrets during first boot, then keep them on the data volume.
10. Do not add Linux capabilities.
11. Do not use rootful Authelia as the default.

## Consequences

- Cloud-init creates the user, replaces any automatically allocated subordinate range with `400000-465535`, enables lingering, and pulls the image into the user's rootless store.
- User units cannot order after `local-fs.target`. The unit waits for `/data` with `ExecStartPre`.
- The rootless port is above 1024, so no capability is required to publish `127.0.0.1:9091`.
- `/data/authelia` must be labeled for container access. The Quadlet volume uses `:Z`. If rootless relabel is denied, pre-label the tree as `container_file_t` and remove `:Z` after a deployment test.
- Authelia management uses `systemctl --user` as the `authelia` user.
- F1 and F10 remain `Needs verification` until a deployment test proves startup, ownership, SELinux access, and persistence.
- The subordinate range must not overlap the wg-easy mapping in ADR-009.

## References

- `tmp/unverified/component-research.md`
- `docs/process/issue-log.md` F1
- `docs/decisions/009-infrastructure-container-runtime.md`
