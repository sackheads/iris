---
name: librarian
description: Organizes workspace files, enforces clean directory structures, and maintains repository hygiene. Use whenever creating new files or scripts, setting up project directories (src/, docs/, scripts/, tests/), writing design specs or implementation plans, or cloning external repositories.
type: skill
timestamp: 2026-07-30T00:00:00Z
---

# Librarian — Workspace & File Organization

## Overview
Agents frequently drop new files, temporary scripts, and unformatted documents directly into the root `./` directory of active workspaces. This skill establishes clear, repeatable file organization and workspace hygiene guidelines for Iris.

## Core Rules & Hygiene

### 1. Active Workspace vs. Standalone Clones
- **Active Workspace Context:** When a conversation has an active workspace set, treat that workspace root as your project root. All relative path operations (`src/`, `docs/`, `scripts/`, `tests/`) MUST be rooted within that active workspace.
- **External Repositories & Clones:** When cloning or initializing a brand-new external repository, place it under `~/src/<repo-name>` or `~/work/<repo-name>`.
- **No `$HOME` Pollution:** Never create git repositories, loose scripts, or dump files directly in `$HOME`.

### 2. Workspace Subdirectory Structure
Keep workspace root directories clean. Organize files into dedicated subdirectories based on their function:
- **`src/` or `Sources/`**: Application source code and implementation modules.
- **`docs/`**: Documentation, architecture guides, and specs.
- **`scripts/`**: Automation scripts, utility tools, and helper commands.
- **`tests/` or `Tests/`**: Test suites, test fixtures, and mock datasets.
- **`assets/`**: Static media, templates, schemas, and bundled binary resources.

### 3. Documentation Conventions
Store design artifacts and reviews strictly in date-prefixed kebab-case files under `docs/`:
- **Design Specs**: `docs/specs/YYYY-MM-DD-feature-name.md`
- **Implementation Plans**: `docs/plans/YYYY-MM-DD-feature-name.md`
- **Peer & Architecture Reviews**: `docs/reviews/YYYY-MM-DD-feature-name-review.md`

*Note on Directory Trees:* Ensure parent subdirectories (`docs/specs/`, `docs/plans/`, `docs/reviews/`, `scripts/`, `tests/`) are created or verified before writing files. `write_file` creates parent directories automatically; for shell operations, run `mkdir -p <dir>` first.

### 4. No Loose Root Files ("No Ants")
- Do NOT write generic temporary scripts (`test.py`, `script.sh`, `temp.md`, `foo.txt`) into root `./`.
- If a temporary script is necessary for verification, write it under `scripts/` or a workspace-scoped `tmp/` directory, and clean it up when completed.
- Descriptive naming is required: use meaningful, self-documenting file names (e.g., `validate-schema.py`, `export-metrics.sh`).

## Summary Checklist Before Writing Files
1. Am I writing to a dedicated subdirectory (`src/`, `docs/`, `scripts/`, `tests/`) rather than workspace root?
2. Does the file name describe its exact purpose without ambiguity?
3. If this is a spec, plan, or review, is it placed under `docs/specs/`, `docs/plans/`, or `docs/reviews/` with a `YYYY-MM-DD-` date prefix?
