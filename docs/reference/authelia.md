---
name: "Authelia Reference"
description: |
  Exact Authelia runtime, authentication, storage, session, secret, and access-control configuration, including the conditions for adding Valkey session storage.
status: draft
version: 1.2
updated: 2026-11-14
---

# Authelia Reference

This page documents this stack's Authelia installation and configuration. It is not an upstream Authelia manual.

## 1. Runtime placement

Authelia runs as a rootless Podman Quadlet user unit under the dedicated `authelia` user. The unit is installed at `/etc/containers/systemd/users/<authelia-uid>/authelia.container`. The source unit is `infra/configs/podman/authelia.container`.

| Property       | Value                                     |
| -------------- | ----------------------------------------- |
| Image          | `authelia/authelia:4.39`                  |
| Published port | `127.0.0.1:9091`                          |
| Configuration  | `/data/authelia/config/configuration.yml` |
| Database       | `/data/authelia/db/authelia.sqlite3`      |
| Environment    | `/data/authelia/env`                      |
| Data volume    | `/data/authelia`                          |

The unit uses `UserNS=keep-id`, `NoNewPrivileges=true`, and `ReadOnly=true`. It waits for the `/data` mount before it starts. The rootless user unit cannot order after `local-fs.target`, so the wait is an `ExecStartPre` loop.

## 2. Configuration source

The tracked source is `infra/configs/authelia/configuration.yml`. The manifest stages it at `/etc/authelia/configuration.yml` and copies it to `/data/authelia/config/configuration.yml` on first boot. The runtime copy is preserved across deployments when it already exists.

The template uses `${DOMAIN}` and environment secrets. Render the template with `tools/render-config.sh` before deployment.

## 3. Authentication backend

The authentication backend is file-based.

| Property           | Value                                       |
| ------------------ | ------------------------------------------- |
| User database      | `/config/users_database.yaml`               |
| Host path          | `/data/authelia/config/users_database.yaml` |
| Password algorithm | Argon2                                      |
| Argon2 variant     | Argon2id                                    |
| Iterations         | 3                                           |
| Memory             | 65536 KiB                                   |
| Parallelism        | 4                                           |
| Key length         | 32                                          |
| Salt length        | 16                                          |

The deployment creates the `admin` user on first boot. It takes the initial password from OCI Vault, generates an Argon2id hash, and writes the user database with mode `0600`.

## 4. Storage

Authelia uses the local SQLite storage provider.

| Property       | Value                                                     |
| -------------- | --------------------------------------------------------- |
| Container path | `/data/authelia.sqlite3`                                  |
| Host path      | `/data/authelia/db/authelia.sqlite3`                      |
| Directory mode | `0700`                                                    |
| Encryption key | `AUTHELIA_STORAGE_ENCRYPTION_KEY` in `/data/authelia/env` |

The Quadlet unit maps `/data/authelia/db` to `/data` inside the container. The SQLite file holds durable Authelia state, including TOTP secrets and registered two-factor devices. It does not store the active session records. Include `/data/authelia/db` in the block-volume backup scope.

The storage encryption key encrypts sensitive database columns. Preserve the key with the database. Do not replace the key after the database contains data. A key change requires the Authelia storage command for encryption key changes.

## 5. Session behavior

The session configuration uses one cookie domain.

| Property     | Value                    |
| ------------ | ------------------------ |
| Cookie name  | `authelia_session`       |
| Domain       | `${DOMAIN}`              |
| Authelia URL | `https://auth.${DOMAIN}` |
| SameSite     | `lax`                    |
| Inactivity   | 5 minutes                |
| Expiration   | 1 hour                   |
| Remember me  | 1 week                   |

Authelia 4.39 uses the in-memory session provider when no `session.redis` block exists. The stack does not configure a session provider. Active sessions are therefore lost when Authelia restarts or when the VM is replaced. The session secret in `/data/authelia/env` persists, so the user must authenticate again but does not lose TOTP enrollment, users, or other durable state.

This behavior is intentional for the single-instance deployment. Losing active sessions is a safe failure mode.

## 6. Access control

The default policy is `deny`.

| Route               | Policy       |
| ------------------- | ------------ |
| `auth.${DOMAIN}`    | `bypass`     |
| `cockpit.${DOMAIN}` | `two_factor` |
| `wg.${DOMAIN}`      | `two_factor` |

Traefik delegates authentication to Authelia through the ForwardAuth endpoint. The Traefik configuration uses `/api/authz/forward-auth`, not the legacy `/api/verify` path.

## 7. Secrets

The deployment generates these values on first boot and stores them in `/data/authelia/env` with mode `0600`:

- `AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET`
- `AUTHELIA_SESSION_SECRET`
- `AUTHELIA_STORAGE_ENCRYPTION_KEY`
- `PUID` and `PGID`
- `UMASK=0077`

Do not store these values in the repository, the manifest, or the configuration template.

## 8. Session persistence alternative with Valkey

Valkey can replace the in-memory session provider if active session persistence becomes a requirement. Valkey does not replace SQLite. Authelia still uses SQLite for durable state, so `authelia.sqlite3` remains required.

Add Valkey only when one of these conditions applies:

1. Authelia runs as more than one instance.
2. Active sessions must survive an Authelia restart or a VM replacement.
3. Valkey is already mandatory for another workload.

Do not add Valkey only to avoid a re-login after a routine restart. The current single-instance deployment does not need that behavior.

Use a dedicated Valkey instance for sessions. Do not reuse the PCP history Valkey. The PCP history service exists only in the `history` monitoring profile, uses a 512 MB cap, and uses the `noeviction` policy. Sharing it makes Authelia login depend on an optional monitoring component.

Suggested session-only Valkey design:

| Property       | Value                           |
| -------------- | ------------------------------- |
| Service        | `valkey-authelia.service`       |
| Listener       | `127.0.0.1:6380`                |
| Memory cap     | 64 MB                           |
| Eviction       | `allkeys-lru`                   |
| Persistence    | AOF with `appendfsync everysec` |
| Data directory | `/data/authelia/valkey`         |

The Authelia configuration would add a `session.redis` block and keep `storage.local.path` unchanged. The rootless Authelia container needs a tested network path to the Valkey listener. A host listener on `127.0.0.1` is not reachable from every rootless Podman network backend without a host gateway address or a shared network.

The 64 MB cap is a planning value. A minimal session-only Valkey is likely to fit the 4 GB profile, but measure resident memory on the target instance before you commit the change.

Valkey adds these operational costs:

- A new mandatory service in every monitoring profile.
- A new login dependency and failure mode.
- SELinux labeling and a data directory on the block volume.
- Backup and restore coverage for session state.
- A deployment test for container-to-host connectivity.

## 9. Deployment and repair

`infra/host/04-authelia.sh` installs or repairs the rootless service. Run it as root from a repository checkout:

```bash
sudo ./infra/host/04-authelia.sh
```

The script performs these actions:

- Creates the `authelia` user and group when absent.
- Enforces the subordinate UID and GID range `400000:65536`.
- Enables lingering and waits for the user manager runtime directory.
- Creates `/data/authelia`, `config`, and `db` with `0700` permissions.
- Creates or repairs `/data/authelia/env` with the required secrets and `PUID`, `PGID`, and `UMASK`.
- Installs `/etc/authelia/configuration.yml` and preserves `/data/authelia/config/configuration.yml`.
- Creates the admin user when `users_database.yaml` is absent.
- Migrates `db.sqlite3`, `storage.sqlite`, or `storage.sqlite3` to `authelia.sqlite3`.
- Installs the Quadlet unit, validates the configuration, restarts the service, and checks `/api/health`.

Set `ADMIN_EMAIL` and either `AUTHELIA_ADMIN_PASSWORD` or `AUTHELIA_ADMIN_SECRET_OCID` for a first bootstrap. When `/etc/authelia/configuration.yml` is absent, set `DOMAIN` so the script can render `infra/configs/authelia/configuration.yml`.

Use `--update-config` to replace the runtime configuration with the staged copy. The script keeps a timestamped backup beside the runtime file first.

The script does not modify the `/data` mount configuration or firewall rules.

## 10. Verification

Run these checks as the `authelia` user or with `runuser`:

```bash
AUTHELIA_UID=$(id -u authelia)
sudo runuser -u authelia -- env XDG_RUNTIME_DIR="/run/user/${AUTHELIA_UID}" \
  systemctl --user status authelia.service
sudo runuser -u authelia -- env XDG_RUNTIME_DIR="/run/user/${AUTHELIA_UID}" \
  podman exec authelia authelia validate-config --config /config/configuration.yml
curl -fsS http://127.0.0.1:9091/api/health
```

The data directories must be owned by `authelia:authelia`, and `/data/authelia` must use the SELinux label required for container access.

## 11. References

- `docs/decisions/002-authelia-runtime.md`
- `docs/decisions/010-monitoring-presentation.md`
- `docs/reference/infrastructure.md`
- `docs/guides/operations.md`
