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
- the prompt resources in `Sources/IrisKit/assets/` (`SYSTEM.md`, `EVALUATOR.md`, the `*-SKILL.md`
  files), by paragraph.

## Why it filters by the diff's words, and also looks beyond the changed files

A changed `iris.swift` would otherwise list 107 descriptions, which no one reads twice. So:

1. take the Swift files under `Sources/IrisKit` the PR changed (`git diff --name-only base...head`);
2. take the words in the diff's added and removed lines under `Sources/`: identifiers split at
   camelCase and underscores (`deadlineClock` gives `deadline` and `clock`), lowercased, four letters
   or more plus a short allow-list of shorter domain words (`vm`, `ask`, `job`), minus a stop-list of
   Swift and English filler (`return`, `guard`, `self`, `string`, …). Strings match on whole words;
3. section 1: each agent-facing string in the changed files that shares at least one of those words,
   most shared words first, with its `file:line` and the words, capped at 40 (the cap says how many
   it dropped);
4. section 2: the 10 agent-facing strings elsewhere in `Sources/` sharing the most words, at least
   two, for a stale sentence in a file the change did not touch.

## Where it runs

A step in `.github/workflows/test.yml`'s `test` job, after the build, writing to
`$GITHUB_STEP_SUMMARY` and always exiting 0. It never fails the job, so it never gets disabled for
crying wolf, which is #198's own warning. `scripts/agent-strings.sh <base> <head>` runs the same
listing locally, and `scripts/agent-strings-test.sh` pins it on a fixture the way
`ci-changes-test.sh` pins `ci-changes.sh`.

## What it would have caught today

- **"fully isolated from the macOS host filesystem"** (Vibecop's in-VM paragraph, fixed in #613).
  #606 changed `VibecopService.swift` (it added the host paragraph), and its changed lines carry
  "approve", "sandbox" and "host", all in the stale paragraph, so it would have been listed on #606,
  well before #613 fixed it.
- **"Wall-clock limit for one run of this job"** (`schedule_job`'s `timeout_seconds` description).
  #626 (the job clock) changes `iris.swift`, and its changed lines carry "clock" and "timeout" (by a
  substring count, which overcounts: "clock" 133 times includes identifiers like `deadlineClock`; the
  whole-word match after the camelCase split still finds "clock"), so the stale description would
  be listed on #626 itself.

Both were in a file the PR touched, though outside its changed lines, which is section 1's case.
Section 2 covers a stale sentence in a file the change did not touch, but only when it shares two or
more words with the change; the template's question and the reviewer's grep remain the answer
beyond that. Not built yet (tracked in #629); the numbers above are from the diffs, by hand.

## Not doing

- No failing check, and no attempt to judge prose against behaviour (#198's non-goals).
- No list of every string on every PR: without the diff filter it is noise.
