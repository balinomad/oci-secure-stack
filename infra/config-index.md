# Deployment source index

This directory is the source tree for deployment inputs and host scripts. It names the files that the deployment writes to the host and maps each file to its target path. The renderer `tools/render-config.sh` reads the manifest and the component lock and fills the generated blocks in `infra/cloud-init/cloud-config.template.yaml`. Do not treat this directory as deployment evidence.

## Layout

Configurations are grouped by component. Each component keeps its native format. Host scripts are grouped by execution environment. Git does not preserve empty directories, so every directory that is part of the source tree contains at least one tracked file.

| Directory               | Contents                                                                       | Status    |
| ----------------------- | ------------------------------------------------------------------------------ | --------- |
| `infra/cloud-init/`     | Cloud-init template with the generated block markers                           | Active    |
| `infra/configs/`        | Declarative component configuration                                            | Active    |
| `infra/host/`           | Host deployment and verification scripts, run from a repository checkout       | Active    |
| `infra/runtime/`        | Staged executable assets that the renderer writes into the cloud-init template | Active    |
| `infra/manifest.yaml`   | Component inventory, resolver sources, and target mapping                      | Active    |
| `infra/config-index.md` | This index                                                                     | Reference |

## Configuration sources

The `infra/configs/` tree contains declarative configuration. The renderer writes every `files` entry into the cloud-config template.

| Directory                   | Contents                                                                                 | Status    |
| --------------------------- | ---------------------------------------------------------------------------------------- | --------- |
| `infra/configs/alerting/`   | Alerting service check list and environment template                                     | Active    |
| `infra/configs/authelia/`   | Authelia configuration and environment template                                          | Active    |
| `infra/configs/cockpit/`    | Cockpit web service configuration                                                        | Active    |
| `infra/configs/grafana/`    | Grafana configuration, provisioning, dashboard, and environment template                 | Active    |
| `infra/configs/oci-vault/`  | OCI Vault policy draft and secret inventory                                              | Reference |
| `infra/configs/pcp/`        | PCP pmproxy, OpenMetrics, and pmie alerting configuration                                | Active    |
| `infra/configs/podman/`     | Podman Quadlet units for Authelia and wg-easy                                            | Active    |
| `infra/configs/prometheus/` | Reserved Prometheus configuration                                                        | Disabled  |
| `infra/configs/systemd/`    | Host systemd units and drop-ins                                                          | Active    |
| `infra/configs/traefik/`    | Traefik static configuration, dynamic configuration, logrotate, and environment template | Active    |
| `infra/configs/valkey/`     | Valkey loopback and persistence configuration                                            | Active    |
| `infra/configs/wg-easy/`    | wg-easy reference configuration and environment template                                 | Active    |
| `infra/configs/wireguard/`  | WireGuard kernel module load file                                                        | Active    |

The `infra/runtime/` tree contains executable assets that the renderer writes. Executable sources must stay under `infra/runtime/`. Do not place executable files under `infra/configs/`.

The `infra/host/` tree contains scripts that run on the target host. The renderer does not write these scripts.

## Manifest

`infra/manifest.yaml` is the machine-readable component manifest. It lists every component in use, the actual target architecture, the resolution source for lockable components, and the file and secret mappings. Component configuration remains under `infra/configs/<component>/` and `infra/runtime/<component>/`.

Top-level fields:

| Field          | Meaning                                                               |
| -------------- | --------------------------------------------------------------------- |
| `version`      | Manifest format version.                                              |
| `architecture` | Actual target architecture. The schema enum defines supported values. |
| `components`   | Component definitions.                                                |

Each component has these fields:

| Field     | Meaning                                                                                                                        |
| --------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `version` | Version constraint for the component. Semver components use `^`, `~`, or an exact value. OS package components use `unpinned`. |
| `source`  | Resolver metadata. Required when `version` is not `unpinned`. Forbidden when `version` is `unpinned`.                          |
| `files`   | Repository-authored files that the renderer writes into the cloud-config template.                                             |
| `secrets` | Runtime-generated secret files. The manifest declares paths and key names, never values.                                       |

A `source` entry has one of these types:

| Type             | Required fields       | Optional fields |
| ---------------- | --------------------- | --------------- |
| `github-release` | `repository`, `asset` | `checksums`     |
| `oci-image`      | `image`               | none            |

The `github-release` fields are:

| Field        | Meaning                                                                                              |
| ------------ | ---------------------------------------------------------------------------------------------------- |
| `repository` | GitHub repository in `owner/name` form.                                                              |
| `asset`      | Asset name template. It must contain `${version}` and `${arch}`.                                     |
| `checksums`  | Checksum file URL template. It must contain `${version}`. Used when the release has no asset digest. |

The `oci-image` `image` field is an image repository without a tag or digest.

Each `files` entry has these fields:

| Field    | Meaning                                                                    |
| -------- | -------------------------------------------------------------------------- |
| `source` | Repository-relative source path under `infra/configs/` or `infra/runtime/` |
| `target` | Absolute host path                                                         |
| `owner`  | Host owner and group                                                       |
| `mode`   | Four-digit octal file mode                                                 |

Each `secrets` entry has these fields:

| Field    | Meaning                                           |
| -------- | ------------------------------------------------- |
| `target` | Absolute host path for the runtime-generated file |
| `owner`  | Host owner and group                              |
| `mode`   | Four-digit octal file mode                        |
| `keys`   | Required environment key names, never values      |

The manifest does not contain secret values.

`infra/manifest.lock.yaml` is the generated component lock. It records the manifest architecture, exact versions, SHA256 digests, and resolved source metadata. `tools/update-lock.sh` is the single generic resolver. It reads the `source` blocks from the manifest and writes the lock. Only components with a `source` block are locked. Do not edit the lock by hand. The renderer injects the target architecture into the first cloud-init command. That preflight stops the deployment before host changes when the instance architecture does not match. The renderer also injects the locked Traefik architecture, repository, asset name, version, and SHA256 into the Traefik release block. It writes `/etc/secure-stack/images.env` from the OCI lock entries. Cloud-init and `infra/host/04-authelia.sh` use those values in Quadlet drop-ins that pin Authelia and wg-easy by digest. `infra/host/03-traefik.sh` and `infra/host/verify-stack.sh` read the lock and reject a host architecture that does not match it. The deployment writes no release metadata file to the host.

## Secret boundary

Do not store secret values, secret OCIDs, private keys, tokens, password hashes, or certificate private keys in `infra/configs/` or `infra/runtime/`. Secret-bearing templates remain outside the `files` list. The manifest declares each runtime secret target and its required key names under `components.<name>.secrets`. Runtime secrets come from OCI Vault. The deployment generates these files:

| Runtime file                                | Source of secret                           |
| ------------------------------------------- | ------------------------------------------ |
| `/etc/traefik/env`                          | `traefik-cloudflare-token`                 |
| `/data/authelia/env`                        | `authelia-admin-password`                  |
| `/data/containers/wg-easy/env`              | `wg-easy-admin-password`                   |
| `/data/monitoring/grafana/env`              | `grafana-admin-password`                   |
| `/data/monitoring/alerting/env`             | `alert-webhook-url`, `alert-heartbeat-url` |
| `/etc/traefik/letsencrypt/acme.json`        | ACME certificate state                     |
| `/data/authelia/config/users_database.yaml` | Bootstrap password hash                    |

The placeholders are `<<INJECT_AT_DEPLOYMENT>>` and `<<INSTANCE_PUBLIC_IP>>`.

## Adding a component

1. Create `infra/configs/<component>/`.
2. Add the file in its native format.
3. Add a `files` entry under the component with `source`, `target`, `owner`, and `mode`.
4. Add a `secrets` entry with `target`, `owner`, `mode`, and `keys` when the deployment creates the file at runtime.
5. Set `version` to a version constraint or to `unpinned` for an OS package component.
6. Add a `source` block when the version is pinned. Omit `source` when the version is `unpinned`.
7. Do not add secret values.
8. Run `tools/validate-manifest.sh` and `tools/render-config.sh --check`.
9. Run `tools/update-lock.sh` when a pinned component is added or changed.

Add executable assets under `infra/runtime/<component>/`. Add host-side scripts under `infra/host/`.

## Current deployment

The template `infra/cloud-init/cloud-config.template.yaml` holds the generated block markers. The renderer `tools/render-config.sh` reads the manifest and the component lock and fills the configuration block, target architecture preflight, locked image environment, and Traefik release block. Run `tools/validate-manifest.sh` to validate the manifest schema. Run `tools/render-config.sh --check` to validate the manifest, sources, and rendered YAML. The deployment procedure at `docs/guides/getting-started.md` runs the renderer before `envsubst`. The process index lists the component manifest, schema, validator, lock, updater, and renderer as implementation sources.
