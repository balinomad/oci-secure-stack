# Security Policy

## Supported versions

This repository contains infrastructure templates and scripts, not versioned software in the traditional sense. The `master` branch is the current supported version.

## Reporting a vulnerability

If you discover a security vulnerability in this repository, report it responsibly. Examples include a misconfiguration, an insecure default, or an exposed secret in a template file. Incorrect security guidance in the documentation is also in scope.

**Do not open a public GitHub issue for security vulnerabilities.**

### How to report

Open a GitHub Security Advisory using the private vulnerability reporting feature. This keeps the report confidential until a fix is available.

Include as much detail as possible:

- Which files are affected
- A description of the vulnerability and its potential impact
- Steps to reproduce or a proof of concept
- Any suggested fix

### Response timeline

- Acknowledgement within 48 hours
- Assessment and initial response within 7 days
- Fix or mitigation published as soon as possible, depending on complexity

## Security design

The security model, threat model, and known limitations are in [docs/architecture.md](docs/architecture.md). Report any control that is insufficient or incorrectly implemented through the process above.
