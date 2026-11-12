---
name: "Resumption Plan"
description: |
  Decision-first plan for resuming work, with phases, tasks, gates, estimates, and immediate next actions.
status: active
version: 1.0
updated: 2026-11-12
---

# Resumption Plan

## Correction to the earlier recommendation

The first assessment recommended proving a deployment before further design work. That order is wrong for this project.

The current implementation contradicts at least six strategic decisions. Deploying it first would test a contract nobody has confirmed. It would also produce findings against a design that is about to change.

Revised order:

1. Establish goals and decision authority.
2. Freeze the decisions that block implementation.
3. Fix only the defects implied by those decisions.
4. Prove the result in a disposable environment.
5. Refactor structure.
6. Write documentation from tested behaviour.
7. Cut over to production.

The implementation remains the evidence source, but it is not the contract.

## Principles

1. Decisions first. No code change without a decision ID or finding ID.
2. Disposable infrastructure for learning. Production receives only proven artifacts.
3. One change per test cycle. Capture the failure and the evidence.
4. Hard-fail on missing persistence. Never run a deployment that silently loses state.
5. Refactor after parity, not before it.
6. Documentation is derived from tested behaviour, not from intent.

## Phase A: Strategic baseline (2-3 days)

Goal: make goals and decisions explicit, tracked, and coherent.

- [ ] A1 Confirm or replace the draft goals in `docs/goals.md`.
- [ ] A2 Answer the seven open questions in `decision-audit.md`.
- [x] A3 Create `docs/decisions/` with numbered ADRs.
- [x] A4 Write ADR-001 exposure model: dashboard, metrics, Cockpit. (draft)
- [x] A5 Write ADR-002 Authelia runtime and file ownership model. (draft)
- [x] A6 Write ADR-003 metrics architecture: PCP export or Traefik only. (draft)
- [x] A7 Write ADR-004 persistence and mount failure policy. (draft)
- [x] A8 Write ADR-005 application container contract and secret handling. (draft)
- [ ] A9 Write ADR-006 backup and recovery scope.
- [ ] A10 Write ADR-007 OCI provisioning method: manual or Terraform.
- [x] A10a Write ADR-008 Traefik runtime. (draft)
- [ ] A11 Mark superseded statements in `docs/legacy/` explicitly.

Gate GA: every goal has an owner, a testable criterion, and no unresolved contradiction. No implementation work starts before this gate.

## Phase B: Repository recovery (0.5 day)

- [x] B1 Move research and planning out of the ignored `docs/tmp/` into tracked paths. (moved 2026-11-12; commit `4a0a2ff`)
- [x] B2 Resolve the uncommitted deletion and `.gitignore` change in one commit. (commit `4a0a2ff`)
- [ ] B3 Tag `v0.1.0-pre-resume`.
- [ ] B4 Create branch `work/decision-baseline`.
- [ ] B5 Add a `docs/process/` revision log entry.

Gate GB: clean working tree, decisions tracked, baseline tagged.

## Phase C: Contract-driven fixes (3-4 days)

Only findings that follow from confirmed decisions are fixed here.

- [ ] C1 Add `scripts/dev/validate.sh`: YAML, cloud-init schema, shellcheck, envsubst completeness.
- [ ] C2 F2 and F3: hard-fail when `/data` is absent or not XFS.
- [ ] C3 F4: abort boot when a Vault secret cannot be fetched.
- [ ] C4 F1: resolve Authelia UID and ownership; prove file access.
- [ ] C5 F5: replace the host-side WireGuard check with a container-side or end-to-end check.
- [ ] C6 F6: implement ADR-001 for dashboard and metrics.
- [ ] C7 F7: attach security headers to the intended routers.
- [ ] C8 F8: implement ADR-003 and remove the self-proxy metrics route.
- [ ] C9 F9: bind Cockpit to localhost and remove the direct firewall rule.
- [ ] C10 F11 and F13: fix manifest permissions and volume validation.
- [ ] C11 F15: verify version pins against upstream.
- [ ] C12 F24: update stale README, `.env.example`, and `CONTRIBUTING.md` paths.

Gate GC: static validation green, every P0 finding closed or explicitly deferred with a decision reference.

## Phase D: Disposable deployment proof (3-5 days)

- [ ] D1 Provision a test instance, blank block volume, test Vault secrets, and test DNS records.
- [ ] D2 Deploy the rendered template and capture `cloud-init status --long` and the full log.
- [ ] D3 Test block volume, Traefik, certificate issuance, Authelia, wg-easy, Cockpit, and the chosen metrics endpoint.
- [ ] D4 Bootstrap the first WireGuard peer over an SSH tunnel and confirm a handshake.
- [ ] D5 Run negative tests: no VPN gives 403, no session redirects to Authelia, HTTP gives 301, TLS is valid, no AVC denials.
- [ ] D6 Reboot and confirm persistence.
- [ ] D7 Rerun cloud-init modules and confirm idempotency.
- [ ] D8 Perform a VM replacement drill with the same block volume.
- [ ] D9 Perform a backup and restore drill if ADR-006 includes it.
- [ ] D10 Archive evidence under `docs/process/evidence/` or in the findings register.

Gate GD: `verify-stack.sh` exits 0 and every item in `deployment-checklist.md` is proven.

## Phase E: Structural refactor (3-5 days)

- [ ] E1 Extract configuration into `configs/`.
- [ ] E2 Populate `scripts/deploy/00-06` as idempotent modules.
- [ ] E3 Implement Makefile targets: `lint`, `render`, `deploy`, `verify`, `backup`.
- [ ] E4 Convert infrastructure containers to Quadlet if ADR-001 or ADR-005 requires it.
- [ ] E5 Clean-room deploy from the refactored tree.
- [ ] E6 Compare behaviour with the Phase D baseline.

Gate GE: parity with the Phase D baseline. No regression.

## Phase F: Documentation (3-4 days)

- [ ] F1 Populate the new documentation tree using the migration map in `docs/process/legacy-migration-map.md`.
- [ ] F2 Write prerequisites and getting started from the tested OCI steps.
- [ ] F3 Write troubleshooting from the actual failures in Phase D.
- [ ] F4 Update README claims and add a tested-on statement with date and version.
- [ ] F5 Add a documentation index and a link check.
- [ ] F6 Archive legacy documents only after every section is mapped and verified.

Gate GF: a new operator can deploy from tracked documentation alone.

## Phase G: Production cutover (2-3 days)

- [ ] G1 Provision production resources.
- [ ] G2 Deploy and verify.
- [ ] G3 Add the first peer, verify access, then close SSH.
- [ ] G4 Enable backups and confirm a restore.
- [ ] G5 Add certificate expiry and disk space checks.
- [ ] G6 Write runbooks: replacement, rotation, upgrade, rollback.
- [ ] G7 Tag `v1.0.0` and add `CHANGELOG.md`.

Gate GG: production checklist passes and rollback is documented.

## Estimates

| Phase                   | Engineer-days |
| ----------------------- | ------------- |
| A Strategic baseline    | 2-3           |
| B Repository recovery   | 0.5           |
| C Contract-driven fixes | 3-4           |
| D Disposable proof      | 3-5           |
| E Refactor              | 3-5           |
| F Documentation         | 3-4           |
| G Production cutover    | 2-3           |
| Total                   | 16.5-24.5     |

Calendar time depends on OCI provisioning and DNS propagation. The plan assumes part-time work.

## Immediate next actions

1. Confirm or replace the goal statement in `docs/goals.md`.
2. Answer Q1 through Q7 in `decision-audit.md`.
3. Track the decision material. Nothing else should start first.
