---
name: "ADR-004: Persistence and Mount Failure Policy"
description: |
  Decision to treat the VM root filesystem as disposable, persist state on the data volume, and fail closed when the data mount is invalid.
status: draft
version: 1.0
updated: 2026-11-12
---

# ADR-004: Persistence and Mount Failure Policy

## Context

The VM root filesystem is treated as disposable, but persistent state must survive VM replacement. Findings F2 and F3 record a non-fatal data mount failure and a filesystem type mismatch. Continuing after a failed mount risks writing state to the root filesystem and losing it.

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
