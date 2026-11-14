---
name: "Application Manifest Reference"
description: |
  Exact format of the application manifest written by infra/host/deploy-service.sh.
status: draft
version: 1.1
updated: 2026-11-14
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
  --admin
```

The cloud-init replay block executes each manifest after the block volume is mounted. Manifests must not contain secret values. Use Podman secrets or root-only environment files.

## Related documents

- Design: `docs/architecture.md`
- Application integration: `docs/guides/adding-apps.md`
- Infrastructure reference: `docs/reference/infrastructure.md`
- Traefik reference: `docs/reference/traefik.md`
