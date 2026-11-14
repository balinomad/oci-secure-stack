---
name: "Document Conventions"
description: |
  Working conventions for project documents, including status, version numbering, commit behavior, placement, and per-document independence.
status: active
version: 1.1
updated: 2026-11-13
---

# Document Conventions

## Document versioning

Scope: every Markdown document under `docs/`.

### Rules

1. Version format is `MAJOR.MINOR`.
2. Normal increments are minor only: `1.0` to `1.1`, `1.1` to `1.2`.
3. Major increments happen only on explicit instruction. Do not increment the major version otherwise.
4. A document increments its minor version at most once per commit. If the current version already differs from the version recorded in the last commit, do not increment it again.
5. Increment the minor version on the first content change after the last commit of the document. The increment takes effect in the next commit.
6. The version increment is part of the same commit as the content change.
7. Each document is versioned independently. Versions are never synchronized across documents.
8. A commit represents at most one minor version change per changed document.
9. Documents not changed by a commit keep their version.
10. A new document starts at `1.0` in its first commit. Subsequent commits increment the minor version to `1.1`, `1.2`, and so on.
11. A metadata-only change, including a frontmatter edit, does not change the version or `updated`.

### Examples

| Situation                                    | Before       | After commit |
| -------------------------------------------- | ------------ | ------------ |
| First commit of a new document               | `1.0`        | `1.0`        |
| One substantive revision                     | `1.0`        | `1.1`        |
| Two documents changed in one commit          | `1.3`, `2.4` | `1.4`, `2.5` |
| New document, edited before its first commit | `1.0`        | `1.0`        |
| Committed document, edit not yet committed   | `1.4`        | `1.5`        |
| Same document, further edits before commit   | `1.5`        | `1.5`        |
| Major rewrite without instruction            | `1.7`        | `1.8`        |
| Major rewrite with explicit instruction      | `1.7`        | `2.0`        |

### Applying the convention

Update the `version:` and `updated:` fields in the document frontmatter. Do not add revision metadata to the document body.

## Document status

Every document declares one status in its frontmatter.

| Value        | Meaning                                           |
| ------------ | ------------------------------------------------- |
| `draft`      | Not confirmed, incomplete, or placeholder         |
| `active`     | Current working record or authoritative reference |
| `legacy`     | Retained for reference, partly superseded         |
| `final`      | Confirmed and verified for the current release    |
| `superseded` | Replaced and no longer authoritative              |

## Document finality

A document is final for the current release when all of these are true:

1. It is committed to git.
2. It has valid frontmatter and the assigned version.
3. Its owner has confirmed its content.
4. It has no unresolved contradiction with the decision record or findings.
5. Every behavioural claim is supported by execution evidence or a direct artifact.
6. It is not marked superseded.

Final does not mean immutable. A later change creates a new version.

The project owner is the repository maintainer. The maintainer confirms document content and decision records.

Project completion criteria are defined in `docs/architecture.md`.

## Documentation layers

### Repository files

`README.md` is the front door. `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE`, and `CHANGELOG.md` are required for a public repository. They are repository policy and metadata files, not core project documentation. Keep them at the repository root and link to the project documentation instead of duplicating it.

### Project documentation

Normative and durable. Describes what the project is and how it must behave.

| Path                                     | Content                                                                                 |
| ---------------------------------------- | --------------------------------------------------------------------------------------- |
| `docs/architecture.md`                   | Purpose, goals, success criteria, constraints, principles, architecture, security model |
| `docs/decisions/`                        | Architecture decision records                                                           |
| `docs/guides/getting-started.md`         | Deployment walkthrough                                                                  |
| `docs/guides/operations.md`              | Verification, maintenance, recovery, and troubleshooting                                |
| `docs/guides/adding-apps.md`             | Application integration contract                                                        |
| `docs/reference/infrastructure.md`       | Exact infrastructure values and host baseline                                           |
| `docs/reference/traefik.md`              | Exact Traefik configuration and maintenance                                             |
| `docs/reference/application-manifest.md` | Exact application manifest format                                                       |

### Process documentation

Retrospective and operational. Describes what happened, what is broken, and how work proceeds.

| Path            | Content                                                                  |
| --------------- | ------------------------------------------------------------------------ |
| `docs/process/` | Status, issue log, plans, acceptance criteria, conventions, and evidence |

### Placement test

Ask one question:

- Does the document state what the project is or how it must behave? Place it in project documentation.
- Does the document record what happened, what is wrong, or how work proceeds? Place it in process documentation.

A document must not mix the two roles. Evidence and status markers do not belong in project documentation. Normative rules do not belong in a status report.

### Operational procedures

Stable procedures belong in `docs/guides/`. A checklist that tracks a one-time deployment belongs in `docs/process/`. When the checklist becomes a reusable operator procedure, move it to `docs/guides/` and update its frontmatter.

### Decision records

Architecture decision records belong in `docs/decisions/`.

An unassigned decision question may be listed in the open decision questions table in `docs/decisions/decision-index.md`. When a draft decision file is created, move the question into that file and remove the table row. Do not keep the question in both places.

### Legacy documents

Legacy source documents are migrated into the project or process layers and then deleted. Do not retain a parallel legacy tree. Record historical provenance in the decision record or issue log that uses it, not in a temporary file.

## Frontmatter

Every Markdown file under `docs/` has frontmatter.

Canonical field order:

```yaml
---
name: "Human-readable document title"
description: |
  Factual one or two sentence summary of the document.
status: draft
version: 1.0
updated: 2026-11-12
---
```

Rules:

1. `name` is a human-readable title.
2. `description` is factual and one or two sentences. No marketing language, no calls to action, and no claims that the document does not support.
3. `status` is one of the values in "Document status".
4. `version` follows the versioning rules in this document.
5. `updated` is the ISO date of the document's last content update.
6. Existing `Revision:` and `Date:` metadata moves from the body into frontmatter. Do not duplicate it in the body.
7. Do not reorder the fields.

## Line breaks

Use a trailing backslash for a hard line break. Do not use two trailing spaces.
