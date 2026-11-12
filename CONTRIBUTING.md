# Contributing

Thank you for considering a contribution to this project.

## What contributions are welcome

- Bug reports: incorrect configuration, broken scripts, outdated software versions
- Documentation improvements: unclear instructions, missing steps, factual errors
- Security improvements: hardening gaps, insecure defaults, better practices
- Compatibility fixes: additional OCI shapes or Oracle Linux 9 image versions

## Before contributing

- Search existing issues to avoid duplicates.
- For security vulnerabilities, follow [SECURITY.md](SECURITY.md). Do not open a public issue.

## How to contribute

1. Fork the repository.
2. Create a branch with a descriptive name.
3. Make your changes.
4. Validate and test them as described in [docs/guides/operations.md](docs/guides/operations.md).
5. Open a pull request with a clear description of what changed and why.

## Guidelines

- **Scripts:** Validate changes to `infra/cloud-init/cloud-config.example.yaml`, `scripts/host/deploy-service.sh`, and `scripts/host/verify-stack.sh` locally. Then run the incremental test procedure in [docs/guides/operations.md](docs/guides/operations.md).
- **Documentation:** Follow [docs/process/document-conventions.md](docs/process/document-conventions.md). Use the document frontmatter. Do not add horizontal rules between sections. Do not use bold text as a header substitute.
- **Documentation checks:** Run `scripts/repo/audit-docs.sh` before opening a pull request. The script checks front matter, links, and document reachability.
- **Software versions:** Pin infrastructure components (Traefik, Authelia, wg-easy) to specific versions. Update the version pin and its evidence together.
- **Secrets:** Never commit real values. Template files use `${VARIABLE}` placeholders processed by `envsubst`. Do not commit `.env` or a rendered `cloud-config.yaml`.
- **Evidence:** Do not claim a deployment behaviour without an execution log, a test result, or a direct artifact. Record findings in [docs/process/issue-log.md](docs/process/issue-log.md).

## Code of conduct

Be respectful. Disagreements about technical approaches are welcome. Personal attacks are not.
