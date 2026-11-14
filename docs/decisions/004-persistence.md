---
name: "ADR-004: Persistence and Mount Failure Policy"
description: |
  Decision to treat the VM root filesystem as disposable, persist state on the data volume, and fail closed when the data mount is invalid.
status: draft
version: 1.2
updated: 2026-11-14
---

# ADR-004: Persistence and Mount Failure Policy

## Context

The VM root filesystem is treated as disposable, but persistent state must survive VM replacement. Findings F2 and F3 record a non-fatal data mount failure and a filesystem type mismatch. Continuing after a failed mount risks writing state to the root filesystem and losing it.

## Affected paths

- `infra/cloud-init/cloud-config.template.yaml:527-539`
- `docs/process/issue-log.md` F2, F3

## Current text or behavior

The template mounts `/data` with a non-fatal `mount /data || true` and accepts any existing filesystem as XFS. A failed or wrong-type mount lets services write to the ephemeral root disk.

## Contradiction

The design requires persistent state on `/data` and a fatal stop when the mount is missing or invalid. The template continues after a failed mount and does not verify the XFS type.

## Options

1. Keep the non-fatal mount and the permissive filesystem check.
2. Make a missing or invalid `/data` mount fatal and verify XFS before starting services.
3. Fall back to the root filesystem when `/data` is unavailable.

## Consequences of each option

- Option 1: services can write state to the ephemeral root disk. Data loss risk remains, and F2 and F3 remain open.
- Option 2: a volume problem stops the stack. Recovery requires repairing or attaching the volume, and F2 and F3 are addressed.
- Option 3: the stack starts without the data volume. State is lost on replacement, and the persistence contract is violated.

## Recommendation

Adopt option 2.

## Decision

1. Treat the VM root filesystem as ephemeral.
2. Store persistent state on the block volume mounted at `/data`.
3. Treat a missing or invalid `/data` mount as a fatal startup error.
4. Verify that the mounted filesystem is XFS before starting services.
5. Do not fall back to the root filesystem when the data volume is unavailable.
6. Make `cloud-init` fail closed and report the failure through the console or journal.

## Consequences

- A volume problem stops the stack instead of silently losing data.
- Recovery requires attaching or repairing the volume before services start.
- F2 and F3 are addressed by explicit checks and fatal errors. Implementation and deployment verification remain.
- The backup and restore procedure must account for a failed boot.

## References

- `tmp/unverified/component-research.md`
- `docs/process/issue-log.md` F2, F3
