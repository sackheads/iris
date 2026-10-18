# Listing the agent-facing strings a PR might have made untrue (#198)

Design only. Option 1 of #198 (the PR template plus the reviewer's check in AGENTS.md) ships first;
this is the cheapest automated aid on top of it that cannot false-fail.

## The idea

A non-failing CI step prints, for the reviewer, the agent-facing strings that sit in the files the PR
changed **and** share a word with the PR's own diff. It decides nothing: it puts the sentences most
likely to have gone stale in front of the person who has to judge them.

## What counts as an agent-facing string

- `description: "…"` literals in `Sources/IrisKit` (tool and parameter descriptions):
  107 in `iris.swift`, 30 in `ToolExecutor.swift`, 13 in `SubagentManager.swift`;
- multi-line literals bound to the prompt constants (`GoalContract.oracleText`,
  `VibecopService.baselinePrompt` and its layer texts, the other `*Prompt`/`*Text` constants in
  `AppState`, `GoalEvaluator`, `DailyDigest`, `AnthropicClient`);
- the prompt resources (`Sources/IrisKit/Resources/*.md`, e.g. `EVALUATOR.md`), whole, when changed.

## Why it filters by the diff's words

A changed `iris.swift` would otherwise list 107 descriptions, which no one reads twice. So:

1. take the Swift files under `Sources/IrisKit` the PR changed (`git diff --name-only base...head`);
2. take the words of five letters or more in the diff's added and removed lines, lowercased, minus
   a short stop-list (`return`, `guard`, `self`, `string`, …);
3. print each agent-facing string in those files that contains at least one of those words, with
   its `file:line` and the matching words, capped at 40 entries (the cap says how many it dropped).

## Where it runs

A step in `.github/workflows/test.yml`'s `test` job, after the build, writing to
`$GITHUB_STEP_SUMMARY` and always exiting 0. It never fails the job, so it never gets disabled for
crying wolf, which is #198's own warning. `scripts/agent-strings.sh <base> <head>` runs the same
listing locally, and `scripts/agent-strings-test.sh` pins it on a fixture the way
`ci-changes-test.sh` pins `ci-changes.sh`.

## What it would have caught today

- **"fully isolated from the macOS host filesystem"** (Vibecop's in-VM paragraph, fixed in #613).
  #606 changed `VibecopService.swift` (it added the host paragraph), and its diff carries "approve"
  and "sandbox" (checked: both appear in its changed lines), both in the stale paragraph, so it would
  have been listed on #606, well before #613 fixed it.
- **"Wall-clock limit for one run of this job"** (`schedule_job`'s `timeout_seconds` description).
  #626 (the job clock) changes `iris.swift`, and its diff carries "clock" (133 times) and "timeout", so the
  stale description would be listed on #626 itself.

Both were in a file the PR touched. That is the listing's limit: a stale sentence in a file the PR
did not touch, describing behaviour that changed elsewhere, is not listed. The template's question
and the reviewer's grep remain the answer for that case.

## Not doing

- No failing check, and no attempt to judge prose against behaviour (#198's non-goals).
- No list of every string on every PR: without the diff filter it is noise.
