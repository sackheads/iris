---
type: skill
title: sandbox-usage
description: How to use the per-conversation sandbox container efficiently (persistent disk state, non-persistent shell state, idle resets).
tags: [sandbox, shell, efficiency]
timestamp: 2026-07-25
---

# Using the Sandbox Efficiently

When sandboxing is enabled, `run_command` runs inside a Linux container that lives for the whole
conversation. The active workspace is mounted at the **same absolute path** as on the host, so a
file written with `write_file` is visible to your commands at that path.

## What persists, what doesn't

- **Disk state persists** within the session: packages you install, files you create, and build
  artifacts remain available to later commands. Install or build once, then reuse — don't
  reinstall every command.
- **Shell state does NOT persist across separate `run_command` calls.** Each command is a fresh
  process, so `cd` and `export` do not carry over. Instead:
  - Chain within one command: `cd subdir && make`.
  - Use absolute paths.
  - Set environment inline: `FOO=bar ./script.sh`.

## Efficiency

- Prefer a few combined commands over many tiny ones. Chaining with `&&` is cheaper and clearer
  than issuing each step as its own `run_command`.

## Idle resets

An idle session's container may be reclaimed after a period of inactivity to free resources. When
that happens, in-container disk state is cleared (your **host workspace files are never touched**).
You will see a notice prefixed to the next command's output:

> `[sandbox] This session's container was reclaimed after being idle; ...`

Treat that notice as a signal to re-run any setup (installs/builds) before relying on it.
