# Deployment source index

This directory is the source tree for deployment inputs and host scripts. It names the files that the deployment writes to the host and maps each file to its target path. The renderer `tools/render-config.sh` reads `infra/manifest.yaml` and fills the generated block in `infra/cloud-init/cloud-config.example.yaml`. Do not treat this directory as deployment evidence.

## Layout

Configurations are grouped by component. Each component keeps its native format. Host scripts are grouped by execution environment. Git does not preserve empty directories, so every directory that is part of the source tree contains at least one tracked file.

| Directory               | Contents                                                                       | Status    |
| ----------------------- | ------------------------------------------------------------------------------ | --------- |
| `infra/cloud-init/`     | Cloud-init template with the generated block markers                           | Active    |
| `infra/configs/`        | Declarative component configuration                                            | Active    |
| `infra/host/`           | Host deployment and verification scripts, run from a repository checkout       | Active    |
| `infra/runtime/`        | Staged executable assets that the renderer writes into the cloud-init template | Active    |
| `infra/manifest.yaml`   | Machine-readable source and target mapping                                     | Active    |
| `infra/config-index.md` | This index                                                                     | Reference |

## Configuration sources

The `infra/configs/` tree contains declarative configuration. The renderer stages the entries marked `stage: true`.

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

The `infra/runtime/` tree contains executable assets that the renderer stages. Executable staged sources must stay under `infra/runtime/`. Do not place executable files under `infra/configs/`.

The `infra/host/` tree contains scripts that run on the target host. The renderer does not stage these scripts.

## Manifest

`infra/manifest.yaml` is the machine-readable mapping. Each entry has these fields:

| Field            | Meaning                                                                                                    |
| ---------------- | ---------------------------------------------------------------------------------------------------------- |
| `source`         | Repository-relative source path under `infra/configs/` or `infra/runtime/`, or `null` for a generated file |
| `target`         | Absolute host path, or `null` for reference material                                                       |
| `runtime_target` | Optional final path when the deployment copies the file after staging                                      |
| `owner`          | Host owner and group, or `null`                                                                            |
| `mode`           | Octal file mode, or `null`                                                                                 |
| `format`         | Native format: `yaml`, `json`, `ini`, `systemd`, `quadlet`, or `text`                                      |
| `validate`       | Validation command, or `null`                                                                              |
| `secret`         | `true` when the file contains or receives secret material                                                  |
| `generated`      | `true` when the deployment creates the file at runtime                                                     |
| `enabled`        | `false` for reserved or reference-only files                                                               |
| `stage`          | `true` when the renderer emits the file into the `write_files` block                                       |
| `status`         | `active`, `reference`, or `reserved`                                                                       |

The manifest does not contain secret values.

## Secret boundary

Do not store secret values, secret OCIDs, private keys, tokens, password hashes, or certificate private keys in `infra/configs/` or `infra/runtime/`. Secret-bearing files are templates with placeholders and `secret: true` in the manifest. Runtime secrets come from OCI Vault. The deployment generates these files:

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
3. Add a manifest entry with the source, target, owner, mode, format, validator, and stage flag.
4. Set `enabled: false` and `status: reserved` when the component is not part of v1.0.
5. Set `stage: false` when the deployment creates the file outside the rendered cloud-config.
6. Do not add secret values.
7. Validate the file with the component's native validator.

Add executable staged assets under `infra/runtime/<component>/`. Add host-side scripts under `infra/host/`.

## Current deployment

The template `infra/cloud-init/cloud-config.example.yaml` holds only the generated block markers. The renderer `tools/render-config.sh` reads the manifest and fills the markers. Run `tools/render-config.sh --check` to validate the manifest, sources, and rendered YAML. The deployment procedure at `docs/guides/getting-started.md` runs the renderer before `envsubst`. The process index lists the manifest and the renderer as implementation sources.
