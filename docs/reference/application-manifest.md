---
name: "Application Manifest Reference"
description: |
  Exact format of the application manifest written by infra/host/deploy-service.sh.
status: draft
version: 1.2
updated: 2026-11-15
---

# Application Manifest Reference

This page defines the application manifest format used by the stack.

## 1. Application manifest format

`infra/host/deploy-service.sh` saves an application manifest to `/data/apps/<app-name>.sh`. The manifest records the original invocation:

```bash
#!/usr/bin/env bash
# Auto-generated deployment manifest for <app-name>
# Created: <timestamp>
<absolute-script-path> \
  --name <app-name> \
  --image <image>:<tag> \
  --port <port> \
  --domain <domain> \
  --volume <volume> \
  --env <name=value> \
  --secret-env <name=ocid> \
  --admin
```

The cloud-init replay block executes each manifest after the block volume is mounted. Manifests are mode `0600` and must not contain secret values. `--secret-env` records the OCI Vault secret OCID. The deploy script fetches the value into `/run/apps/<app-name>/env` with mode `0600`.

## Related documents

- Design: `docs/architecture.md`
- Application integration: `docs/guides/adding-apps.md`
- Infrastructure reference: `docs/reference/infrastructure.md`
- Traefik reference: `docs/reference/traefik.md`
