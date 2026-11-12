#!/usr/bin/env python3
"""Internal documentation audit. NOT A DELIVERABLE.

This is a repository maintenance tool. It is not part of the deployed stack,
is not referenced by the deployment process, and must not be treated as a
project deliverable.

It checks the rules in docs/process/document-conventions.md:
- required frontmatter fields
- allowed status values
- version and updated formats
- no duplicate frontmatter fields
- no body metadata outside code blocks
- internal links resolve
- exactly one trailing newline
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REQUIRED = ["name", "description", "status", "version", "updated"]
CANONICAL_ORDER = {name: index for index, name in enumerate(REQUIRED)}
ALLOWED_STATUS = {"draft", "active", "legacy", "final", "superseded"}

FRONTMATTER_KEY_RE = re.compile(r"^([A-Za-z_]+):")
META_LINE_RE = re.compile(
    r"^(Status|Version|Date|Owner|Author|Revision|Updated|Last updated|"
    r"Document status|Document version)\s*:",
    re.I,
)
META_HEADING_RE = re.compile(r"^#{1,6}\s+(Status|Version|Metadata|Revision)\s*$", re.I)
LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
FENCE_RE = re.compile(r"^(`{3,}|~{3,})")


def add_error(errors: list[str], path: Path, line: int | None, message: str) -> None:
    location = f"{path}:{line}" if line is not None else str(path)
    errors.append(f"{location}: {message}")


def parse_frontmatter(path: Path, lines: list[str], errors: list[str]) -> int | None:
    if not lines or lines[0].strip() != "---":
        add_error(errors, path, 1, "missing frontmatter")
        return None

    try:
        end = lines.index("---", 1)
    except ValueError:
        add_error(errors, path, 1, "unclosed frontmatter")
        return None

    frontmatter_lines = lines[1:end]
    keys: list[tuple[str, int]] = []
    for offset, line in enumerate(frontmatter_lines, start=2):
        match = FRONTMATTER_KEY_RE.match(line)
        if match:
            keys.append((match.group(1), offset))

    seen: dict[str, int] = {}
    for key, line_number in keys:
        if key in seen:
            add_error(errors, path, line_number, f"duplicate frontmatter field: {key}")
        else:
            seen[key] = line_number

    for field in REQUIRED:
        if field not in seen:
            add_error(errors, path, 1, f"missing frontmatter field: {field}")

    ordered = [key for key, _ in keys if key in CANONICAL_ORDER]
    if ordered != sorted(ordered, key=CANONICAL_ORDER.get):
        add_error(errors, path, 2, f"frontmatter order must be: {', '.join(REQUIRED)}")

    frontmatter = "\n".join(frontmatter_lines)

    status_match = re.search(r"^status:\s*(\S+)", frontmatter, re.M)
    if status_match and status_match.group(1) not in ALLOWED_STATUS:
        add_error(errors, path, seen.get("status"), f"invalid status: {status_match.group(1)}")

    version_match = re.search(r"^version:\s*(\S+)", frontmatter, re.M)
    if version_match and not re.fullmatch(r"\d+\.\d+", version_match.group(1)):
        add_error(errors, path, seen.get("version"), f"invalid version: {version_match.group(1)}")

    updated_match = re.search(r"^updated:\s*(\S+)", frontmatter, re.M)
    if updated_match and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", updated_match.group(1)):
        add_error(errors, path, seen.get("updated"), f"invalid updated date: {updated_match.group(1)}")

    return end + 1


def iter_body_lines(
    lines: list[str], body_start: int
) -> list[tuple[int, str]]:
    result: list[tuple[int, str]] = []
    fence_char: str | None = None
    fence_length = 0

    for offset, line in enumerate(lines[body_start:], start=body_start + 1):
        stripped = line.lstrip()
        match = FENCE_RE.match(stripped)

        if fence_char is None:
            if match:
                fence_char = match.group(1)[0]
                fence_length = len(match.group(1))
                continue
            result.append((offset, line))
            continue

        if (
            match
            and match.group(1)[0] == fence_char
            and len(match.group(1)) >= fence_length
        ):
            fence_char = None
            fence_length = 0

    return result


def strip_inline_code(line: str) -> str:
    return re.sub(r"(`+)(?:(?!\1).)*\1", "", line)


def check_body(path: Path, lines: list[str], body_start: int, errors: list[str]) -> None:
    for line_number, line in iter_body_lines(lines, body_start):
        stripped = line.strip()
        if META_LINE_RE.match(stripped):
            add_error(errors, path, line_number, f"body metadata: {stripped}")
        if META_HEADING_RE.match(stripped):
            add_error(errors, path, line_number, f"body metadata heading: {stripped}")

        for match in LINK_RE.finditer(strip_inline_code(line)):
            target = match.group(1).strip()
            if target.startswith("<") and target.endswith(">"):
                target = target[1:-1]
            if target.startswith(
                ("http://", "https://", "mailto:", "tel:", "data:", "ftp://", "#", "/")
            ):
                continue
            target_path = target.split("#", 1)[0]
            if not target_path:
                continue
            target_path = target_path.split()[0]
            if not (path.parent / target_path).resolve().exists():
                add_error(errors, path, line_number, f"broken link: {target}")


def audit_file(path: Path) -> list[str]:
    errors: list[str] = []
    raw = path.read_text(encoding="utf-8")

    if "\r" in raw:
        add_error(errors, path, None, "CRLF line endings")
    if not raw.endswith("\n") or raw.endswith("\n\n"):
        add_error(errors, path, None, "must end with exactly one newline")

    lines = raw.splitlines()
    body_start = parse_frontmatter(path, lines, errors)
    if body_start is not None:
        check_body(path, lines, body_start, errors)

    return errors


def main() -> int:
    default_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="Internal documentation audit (not a deliverable)."
    )
    parser.add_argument(
        "root",
        nargs="?",
        default=default_root,
        help=f"repository root (default: {default_root})",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    docs_dir = root / "docs"
    if not docs_dir.is_dir():
        print(f"ERROR {docs_dir}: docs directory not found", file=sys.stderr)
        return 1

    docs = sorted(docs_dir.rglob("*.md"))
    errors: list[str] = []
    for path in docs:
        errors.extend(audit_file(path))

    for error in errors:
        print(f"ERROR {error}")
    print(f"docs: {len(docs)}, errors: {len(errors)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
