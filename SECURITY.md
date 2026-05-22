# Security Policy

## Supported Versions

This repository contains infrastructure templates and scripts, not versioned software in the traditional sense. The `master` branch is always considered the current supported version.

## Reporting a Vulnerability

If you discover a security vulnerability in this repository — including misconfigurations, insecure defaults, exposed secrets in template files, or incorrect security guidance in the documentation — please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

### How to Report

Open a GitHub Security Advisory using the private vulnerability reporting feature. This keeps the report confidential until a fix is available.

Include as much detail as possible:

- Which file(s) are affected
- A description of the vulnerability and its potential impact
- Steps to reproduce or a proof of concept if applicable
- Any suggested fix if you have one

### Response Timeline

- Acknowledgement within 48 hours
- Assessment and initial response within 7 days
- Fix or mitigation published as soon as possible depending on complexity

## Security Design Notes

This stack is designed with the following security principles:

- No credentials are embedded in the template — all secrets are fetched from OCI Vault at boot time via Instance Principal authentication
- All admin services are restricted to the WireGuard VPN subnet via Traefik `ipAllowList` middleware
- Authelia provides TOTP-based MFA for all admin routes
- SELinux is enforcing on the host OS
- Traefik runs as a dedicated non-root system user with minimal Linux capabilities
- TLS certificates are issued automatically via Let's Encrypt; no plaintext HTTP traffic reaches any backend

If you believe any of these controls are insufficient or incorrectly implemented, please report it via the process above.
