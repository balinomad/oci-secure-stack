# Work Plan

## Phase 1: Triage & Decision Making (Conflicts)

_Goal: Resolve architectural contradictions._

- [x] Decide on Dashboard/Metrics exposure (Resolved: Localhost + SSH).
- [x] Formally document the Traefik native-binary architectural decision (Resolved: Native Binary).

## Phase 2: Research & Scope Definition (Missing Info)

_Goal: Investigate and define the technical requirements for missing components before writing documentation._

- [ ] **Cockpit:** Research OL9 Cockpit installation, proxy header requirements for Traefik, and PAM/Authelia integration boundaries.
- [ ] **Prometheus & PCP:** Research PCP metric extraction, Prometheus server deployment (Podman Quadlet), scrape target configurations, and storage retention policies.
- [ ] **Authelia Deep Dive:** Research `configuration.yml` structure, SQLite vs. Postgres backend, TOTP enforcement policies, and user/group management workflows.

## Phase 3: Architecture & Specifications

_Goal: Establish the foundational design documents._

- [ ] **`docs/architecture.md`**: Synthesize high-level design, network flows, immutable infrastructure philosophy, and the localhost-management-plane decision.
- [ ] **`docs/specifications/infrastructure.md`**: Detail OCI prerequisites (VCN, NSG, Vault IAM, DNS) and `cloud-init` logic.
- [ ] **`docs/specifications/storage.md`**: Detail the `/data` layout, symlinks, and Restic backup strategy.

## Phase 4: Component Deep-Dives

_Goal: Migrate and expand technical specifications for each service using Phase 2 research._

- [ ] **`docs/components/traefik.md`**: Adapt `traefik-guide.md`. Enforce localhost bindings and native systemd hardening.
- [ ] **`docs/components/authelia.md`**: Draft new based on Phase 2 research.
- [ ] **`docs/components/wireguard.md`**: Extract wg-easy details and peer management.
- [ ] **`docs/components/podman.md`**: Extract Quadlet rules, image building, and network conventions.
- [ ] **`docs/components/cockpit.md`**: Draft new based on Phase 2 research.
- [ ] **`docs/components/monitoring.md`**: Draft new (Prometheus/PCP) based on Phase 2 research.

## Phase 5: Operational Guides & Integration

_Goal: Create user-facing runbooks and developer integration guides._

- [ ] **`docs/guides/getting-started.md`**: Step-by-step deployment flow.
- [ ] **`docs/guides/adding-apps.md`**: Adapt `app-integration-guide.md` (Responsibility boundaries, Quadlet, Traefik routing).
- [ ] **`docs/guides/security-headers.md`**: Adapt CSP and global headers logic.
- [ ] **`docs/guides/maintenance.md`**: Adapt updates, secret rotation, and VM replacement procedures.
- [ ] **`docs/guides/troubleshooting.md`**: Adapt incremental testing and common failure patterns.

## Phase 6: Implementation & Coding

_Goal: Translate finalized documentation into executable infrastructure._

- [ ] Refactor `infra/cloud-init/cloud-config.example.yaml` to match finalized specifications (removing public routes for dashboard/metrics).
- [ ] Split `deploy-service.sh` and `verify-stack.sh` into modular, idempotent scripts in `scripts/`.
- [ ] Populate `configs/` with finalized application and infrastructure templates.
- [ ] Implement `Makefile` targets.
