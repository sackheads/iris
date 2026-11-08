---
type: spec
title: Role-marker sanitizer — stop corrupting legitimate content
issue: 952
status: draft (for review before planning)
timestamp: 2026-11-08
---

# Role-marker sanitizer: fidelity without losing the turn-forge defense

## Intent

The prompt-injection guard strips LLM role delimiters (`model:`, `user:`, `system:`,
`assistant:`, `Instruction:`, `System Prompt:`, chat-template tokens, `---`/`###`) from
untrusted tool output so an untrusted line cannot impersonate a real conversation turn. The
strip is **destructive** and **anywhere-in-line**, and the stripped text is what the model
*sees*. That silently corrupts legitimate content — and because `read_file` of a non-Iris
path runs through this path, a read→edit→`write_file` round-trip **persists the corruption to
disk**.

Goal: preserve the content faithfully while keeping the guard's turn-forge defense intact.
This is a change to a security trust boundary; it must not be loosened in a way that lets an
injected turn through.

## The bug, precisely (verified 2026-11-08)

- Untrusted text flows: `InjectionGuard.sanitizeUntrusted` → `classifyUntrusted` →
  `PromptInjectionGuard.stripRecordingDelimiters` (`PromptInjectionGuard.swift:24-27`), using
  `malRolePatterns` which **includes `model:`** (`PromptInjectionGuard.swift:53-64`).
- The strip is a whole-word regex (`(?<![A-Za-z0-9_])`, `PromptInjectionGuard.swift:98-102`),
  case-insensitive, matching **anywhere in a line, not only at line start** (deliberate,
  comment `PromptInjectionGuard.swift:89-90`).
- The **stripped** text becomes the model-visible content:
  `sanitizeUntrusted` → `wrapped(.passed(clean))` where `clean` derives from the already-
  stripped text (`InjectionGuard.swift:382-387`, `356-361`).
- `read_file` of a path **not** under `~/.iris` is marked untrusted (`iris.swift:7147`) and
  routed through this guard at tier 3 (`iris.swift:7156`). (A first-party read **under** the
  Iris dir returns raw, `iris.swift:7139-7143`.) So an ordinary config/source read is
  corrupted in the model's view, and writing it back persists the loss.

Common casualties: YAML/config keys `user:` (docker-compose, systemd), `system:`, `model:`
(every LLM config). This is not a rare collision.

### Already mitigated — do NOT re-solve these
- Word-boundary anchoring (#736/#742): `filesystem:`, `data_model:`, `subsystem:` are safe.
- The "nesting bypass" `momodel:del:` does **not** collapse to a stripped `model:` here (the
  inner `model:` is preceded by a letter; the lookbehind blocks it).
- The `mo<ZWSP>del:` split is closed: `normalize()` NFKC-folds and strips U+200B + control
  chars first (`PromptInjectionGuard.swift:35-48`).

The defect is the **destructive deletion of legitimate content**, not bypassability.

## Inconsistency to reconcile

Two marker lists disagree: the untrusted path strips `model:`
(`PromptInjectionGuard.swift:53`), but `InjectionGuard`'s own internal strip does not
(`InjectionGuard.swift:565`, only `system:`/`assistant:`/`user:`/`---`/`###`). The fix should
leave one coherent story about which markers are neutralized where.

## The invariant that must hold (non-negotiable)

1. **No turn forge.** Untrusted tool output can never be read by the model as a genuine
   conversation turn (`system:`/`assistant:`/`user:`/`model:` opener, chat-template token).
2. **Classifier signal preserved.** Tier 2/3 must still receive the per-line delimiter signal
   (`delimiterLines`, #727) so a malicious forged-turn line is scored and blocked as today.

## Goals / non-goals

**Goals**
- A benign file containing `model:`/`user:`/`system:` lines round-trips
  `read_file → model → write_file` **byte-identical**.
- The model reads faithful content from all untrusted channels (read_file, web, search,
  conversation), not a holed version.
- One coherent marker-handling story across the two code paths.

**Non-goals**
- Changing the tier-2/tier-3 classifiers or their thresholds.
- Changing what counts as untrusted, or the `read_file` routing.
- Time-of-day or any unrelated guard work.

**Anti-goals**
- Any change that lets an injected `system:`/`model:` turn in untrusted output be read as a
  real turn. If the fidelity fix cannot preserve the forge defense, it does not ship.

## Design direction (recommended; the review validates it)

**Decouple classification from display.** Keep scoring the normalized + stripped text, with
delimiter lines scored alone (unchanged detection). But present the model the **original
bytes** of content the guard **passed**, inside the existing `<untrusted_context source=…>`
wrapper (with its breakout-closing-tag escaping).

The security argument this rests on, which the review must confirm:
- The **classifier** is the real defense against a *malicious* forged turn: a line with a
  strong delimiter is scored alone and a malicious one is **blocked** — it is never displayed
  at all, marker or no marker. Deletion therefore only ever altered content that **passed**
  (was judged benign), where neutralizing an incidental `model:` buys almost no security and
  causes the corruption.
- The **wrapper** is the backstop for classifier false-negatives: benign-scored content sits
  inside `<untrusted_context>`, which the model is instructed to treat as data, and breakout
  closing tags are escaped so the content cannot leave the wrapper and inject real turns.

So the deletion is belt-and-suspenders over two existing defenses, paid for in corrupted
reads and corrupted write-backs.

### Fallback if the review finds the wrapper insufficient
Restrict neutralization to **line-start** markers only (where a real turn opener lives),
matching the existing line-start logic for `---`/`###` (`delimiterBeforeRole`,
`PromptInjectionGuard.swift:84-85`). This preserves every mid-line occurrence (`the model:`),
which is the bulk of the collateral, while keeping a structural guard at the one position a
forge needs. It does **not** fully fix a YAML key sitting at line-start; note that residue
explicitly if chosen.

## Required review

This reopens a security trust boundary (#727/#735/#736/#742). Route the review to a **dev**,
not the work session (its classifier declines guard/sandbox reviews). The reviewer must
confirm, with evidence, that the turn-forge invariant still holds under the chosen design —
specifically that an existing malicious forged-turn dataset row is still blocked, and that no
benign row leaks a readable-as-turn line.

## Acceptance / test matrix

- **Fidelity:** a fixture file with lines `model: gpt-x`, `user: alice`, `system: prod` reads
  back through the untrusted guard byte-identical to disk; a read→write round-trip of that
  file produces an identical file. (Use the real guard, `protectionEnabled: true`.)
- **Mid-line prose:** "reaches the model: foo" survives intact.
- **Forge still blocked:** an **existing** malicious injection row (reuse a dataset row framed
  as tool output — do NOT author a new payload) that forges a `system:`/`model:` turn is still
  blocked / cannot be read as a turn. Owner-authorized guard evals only.
- **Classifier signal intact:** the existing #727 delimiter-line-scored tests stay green.
- **Consistency:** the `model:`-list discrepancy between the two paths is resolved (one test
  pins the intended behavior for both).
- **No regression:** full suite green; `scripts/check-warnings.sh` clean.

## Falsification (Invariant 9)
Grep for what this changes: the guard comments at `iris.swift:6011-6015` and `6096-6101` state
that `sanitizeUntrustedInput` strips these markers from guarded text — if the fix stops doing
that on display, those comments and the `search_conversations`/`read_conversation` "owner"/
"iris" substitutions that exist *because* of the strip must be re-checked and corrected. Also
`docs/prompt_injection_guard_design.md` and any agent-facing guard description.
