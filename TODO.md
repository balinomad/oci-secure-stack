# TODO

- [x] `oracle-cloud-init` is too narrow, as the scope covers Podman, Traefik, Authelia, and monitoring. Rename to `oci-secure-web-stack`, `oci-homelab-stack`, or `oracle-cloud-self-hosted`. Update the name via GitHub Settings and update your local `git remote` URL.
- [ ] Documentation Strategy: one master architecture document, individual component documents, and integration/maintenance guides. A single monolithic document becomes unmaintainable, difficult to search, and hard to update as stack versions change.
- [ ] Avoid putting application source code in this repo. Keep it strictly to infrastructure and orchestration.
- [ ] Use a `Makefile` or `Taskfile` to abstract complex script invocations for the end-user (e.g., `make deploy-traefik`).
- [ ] Ensure all deployment scripts are idempotent so they can be safely re-run if an instance reboots or a step fails.
