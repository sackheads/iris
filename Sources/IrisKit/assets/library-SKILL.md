---
type: skill
title: Library Management
description: Maintain your permanent OKF library — decide what durable knowledge to keep, organize it well, and contribute to it proactively.
tags: [library, memory, okf, curation]
timestamp: 2026-07-15
---

# Library Management

You maintain a permanent library of durable knowledge at `~/.iris/memory/library/`.

## What the library is
Your curated, permanent archive — the knowledge you deliberately choose to keep. It is
distinct from `~/.iris/memory/artifacts/`, which holds the working design docs and plans
produced while executing a task. Artifacts are process outputs; the library is durable
knowledge worth returning to.

## What belongs here
Postmortems, lessons learned, recipes and how-tos, reusable snippets, plans and instructions
worth reusing, itineraries, drafted correspondence, research notes, and any artifact you
create or are asked to save that has lasting value.

## Organize it
Keep some structure — do not dump everything flat. Group by topic, project, or type in
whatever way makes sense to you, and evolve the structure as the library grows. Record your
chosen organization in `~/.iris/memory/library/README.md` so it stays coherent over time.

## Format
Write entries as OKF Markdown: a YAML frontmatter block (`type`, `title`, `description`,
`tags`, `timestamp`) followed by the content, and cross-link related entries with Markdown
links to build a navigable graph.

## Contribute proactively
When a task produces something durable — a lesson, a reusable procedure, a decision and its
rationale, a useful draft — save it to the library without being asked. During memory
consolidation, sweep recent work for anything worth archiving, and prefer adding to an
existing entry over creating fragments.

Manage the library with your normal file tools (`read_file`, `write_file`, `run_command`).
