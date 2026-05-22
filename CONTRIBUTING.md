# Contributing

Thank you for considering a contribution to this project.

## What Contributions Are Welcome

- Bug reports — incorrect configurations, broken scripts, outdated software versions
- Documentation improvements — unclear instructions, missing steps, factual errors
- Security improvements — hardening gaps, insecure defaults, better practices
- Compatibility fixes — support for additional OCI shapes, Oracle Linux versions

## What to Check Before Contributing

- Search existing issues to avoid duplicates
- For security vulnerabilities, follow the process in [SECURITY.md](SECURITY.md) — do not open a public issue

## How to Contribute

1. Fork the repository
2. Create a branch: `git checkout -b fix/description-of-fix`
3. Make your changes
4. Test your changes following the strategy in `testing-guide.md`
5. Open a pull request with a clear description of what changed and why

## Guidelines

- **Scripts:** Changes to `cloud-config.example.yaml`, `deploy-service.sh`, or `verify-stack.sh` must be tested following `testing-guide.md` before submitting a pull request
- **Documentation:** Follow the markdown format rules established in the existing documents — no `---` horizontal rules between sections, no bold as header substitutes, `.yaml` extension for YAML files
- **Software versions:** Pin to specific minor versions for infrastructure components (Authelia, Traefik, wg-easy); update the relevant comment when changing a version
- **Secrets:** Never commit real values — template files use `${VARIABLE}` placeholders processed by `envsubst`

## Code of Conduct

Be respectful. Disagreements about technical approaches are welcome; personal attacks are not.
