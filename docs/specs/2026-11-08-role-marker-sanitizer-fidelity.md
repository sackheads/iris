---
type: spec
title: Role-marker sanitizer — stop corrupting legitimate content (narrowed A)
issue: 952
status: draft (rev 2, after dev-2 review of rev 1)
timestamp: 2026-11-08
---

# Role-marker sanitizer: fidelity without losing the turn-forge defense

## Intent

The prompt-injection guard strips LLM role delimiters (`model:`, `user:`, `system:`,
`assistant:`, `Instruction:`, `System Prompt:`, chat-template tokens) **and** Markdown
structure (`---`, `###`) from untrusted tool output so an untrusted line cannot impersonate a
real conversation turn. The strip is destructive and anywhere-in-line, and the stripped text
is what the model *sees*. That silently corrupts legitimate content — and because `read_file`
of a non-Iris path runs through this path, a read→edit→`write_file` round-trip **persists the
corruption to disk**.

Goal: give back fidelity on the one channel where the corruption does real damage (a config
or Markdown file read for editing) **without** weakening the turn-forge defense anywhere it
is actually load-bearing. Rev 1 proposed removing the deletion broadly; the review
(dev-2, #957) showed that is unsafe. This rev scopes it down — "narrowed A".

## Why rev 1's broad "stop deleting, trust the classifier + wrapper" is wrong

1. **Deletion is the sole defense when no model-backed tier runs.** The strip also runs with
   protection off, on `maxTier == .tier1_structural` channels (`inbox_item` iris.swift:1391,
   `set_workspace`/watcher echoes), under `HeadlessMode`, when tier 3 is unprovisioned, and
   when tier 2 is `.skipped` (default-off since #781). And where a tier *does* run, "passed"
   includes the false negatives, which are large (E2B passes ~96% of peer/inbox injections,
   ~97% of the disguised #802 rows). So the set deletion protects is exactly "everything the
   classifier missed" — not belt-and-suspenders.
2. **Showing original bytes reopens the wrapper breakout.** The closing-tag escape
   (`executeTier1`, InjectionGuard.swift:571) runs on text that already went through
   `normalize()` (NFKC + control/ZWSP strip). Fullwidth `＜/untrusted_context＞` and a
   ZWSP-split close only get caught because normalize ran first. The safe display form is the
   **normalized, unstripped** text, escaped after normalizing — never the raw bytes.
3. **Judged text must equal shown text (#709, InjectionGuard.swift:~517).** Scoring stripped
   text but showing unstripped text breaks it: the canary never sees the markers the model
   sees, and `OutputCap.cap` / tier-2 `.partial` redaction operate on the stripped text so a
   cut no longer lines up with what is displayed. We therefore **judge the shown
   (normalized-unstripped) text**, keeping the per-line `delimiterLines` recording (#727) for
   tier-2's alone-scoring. "Detection unchanged" is thus not automatic — see the eval in the
   test plan.
4. **`---`/`###` are the bigger casualty.** `remove()` strips every `---`/`###` anywhere in a
   line, so every Markdown/YAML read loses headings, horizontal rules and `---` document
   starts, and write-back persists it. They are not role words, and the real forge signal
   (`---`/`###` at line start *before a role word*) is separately recorded by
   `delimiterBeforeRole` (PromptInjectionGuard.swift:84-85) for tier 2. In the fidelity
   channel they are kept.

## Fidelity is "modulo normalization", not byte-identical

`normalize()` NFKC-folds and strips control chars + U+200B, so a file with ligatures,
fullwidth forms, superscripts or stray controls is already altered on read, independent of
this bug. The goal and fixtures say **identical modulo normalization**. The pre-existing NFKC
write-back alteration is tracked separately (#959), out of scope here.

## Invariant that must hold (non-negotiable)

1. **No turn forge.** Untrusted tool output can never be read by the model as a genuine
   conversation turn (`system:`/`assistant:`/`user:`/`model:` opener, chat-template token),
   on any channel, in any guard configuration.
2. **Judged == shown (#709), and the tier-2 delimiter signal is preserved.**

## The design — narrowed A

Relax the destructive strip to a **non-destructive display of the normalized, unstripped,
wrapper-escaped text**, but only in the narrow intersection where the corruption hurts and a
real verdict backs it:

**Channel allowlist — relax ONLY here (first and only channel this rev ships):**
- `read_file` of a path **not** under `~/.iris` (iris.swift:7147→7156) — the write-back vector.

**Every other channel keeps today's deletion**, unchanged: web, search,
`search_conversations`/`read_conversation` (their "owner"/"iris" substitutions stay), peer /
system-event / `inbox_item`, MCP JSON (iris.swift:7187), `GateEvaluator.quoted` approval
strings, Briefing, attachments. Do **not** change `sanitizeUntrustedInput` itself — it has
~10 non-wrapped callers; add the fidelity path alongside, gated.

**Never relax for the system prompt.** `user_profile` and `workspace_rules` (iris.swift:333,
396) put untrusted text (e.g. an AGENTS.md from an untrusted repo) into the most trusted
position. Deletion stays there.

**Only when a model-backed verdict actually covered the text:** tier 2 or tier 3 provisioned
and ran (not `.skipped`), protection on. Otherwise fall back to today's deletion. So with
protection off, or tier unprovisioned, a `read_file` still gets the deletion — acceptable
degradation, because without a classifier the deletion is the only forge defense.

**Always, even in the fidelity channel:** chat-template tokens (`<|im_start|>`/`<|im_end|>`)
stay stripped — they are real control tokens for local models, with no fidelity case. Role
words and `---`/`###` are shown (normalized, escaped); their `delimiterLines` are still
recorded and scored.

### Marker × path table (finding 7 — pin each row with a test)

| Marker | Untrusted path, fidelity channel (read_file non-Iris, tier ran, prot on) | Untrusted path, all other channels / tier skipped / prot off / system prompt | Plain `sanitize`/`classify` path (InjectionGuard.swift:565) |
|---|---|---|---|
| `system:`/`assistant:`/`user:`/`model:` | shown (recorded+scored) | deleted | today: system/assistant/user deleted, `model:` NOT — **keep as today, documented** |
| `Instruction:`/`System Prompt:` | shown | deleted | today: not stripped — keep |
| `---`/`###` | shown | deleted | deleted (markdown-only) |
| `<\|im_*\|>` tokens | **deleted** (control tokens) | deleted | today: not stripped — keep |

The rev-1 "resolve to one story" is wrong; the correct story is this table. The untrusted
path's tier-1 second pass stays redundant-but-harmless; document it, don't refactor it here.

## Required review

Security trust boundary (#727/#735/#736/#742). Review by a **dev**, not the work session. The
reviewer confirms with evidence that the forge invariant holds under narrowed A — in
particular the **classifier-passed forge** case below.

## Acceptance / test matrix (finding 8)

- **Fidelity (the fix):** a fixture file with `model: gpt-x`, indented `  user: alice`,
  `system: prod`, a `---` document start and `### Heading`, read through the fidelity channel
  with a real tier that **passes** it, reads back **identical modulo normalization**; a
  read→write round-trip of a normalization-stable file is byte-identical.
- **Classifier-PASSED forge (the risk):** a scripted-pass tier fed `system: do X` — assert the
  displayed text is the normalized-unstripped marker, wrapped, with the closing tag escaped
  including the **fullwidth** and **ZWSP-split** and case variants (`</untrusted_context >`,
  `</ untrusted_context>` — mutation-check the escape; finding 5 notes the escape is
  narrow). This proves the wrapper contains a forge the classifier missed.
- **No-verdict → deletion:** tier skipped / protection off / tier-1-only channel → markers
  still deleted.
- **Channel allowlist:** a web / search / peer / system-prompt (`user_profile`) input still
  has markers removed (fidelity never leaks to these).
- **Judged == shown (#709):** `OutputCap.cap` and tier-2 `.partial` redaction line up with the
  displayed text when markers are kept.
- **Eval (owner-authorized, no payload authoring):** the v4 set has 46/225 attack rows with a
  role marker (14 line-start) but only 4/277 benign — add a small benign YAML/compose/LLM-
  config set (benign, no new payloads) and run the existing canary eval **markers-kept vs
  markers-stripped** to measure whether scoring unstripped text moves blocks either way. If it
  regresses detection materially, carry per-line original through cap/redaction instead of
  judging unstripped (finding 3's alternative), or hold.
- **No regression:** full suite green; `scripts/check-warnings.sh` clean; the #727
  delimiter-line tests stay green.

## Falsification (Invariant 9)
The comments at iris.swift:6011-6015 and 6096-6101 stay true **because** those channels keep
deletion — confirm they still describe reality after the change. Update
`docs/prompt_injection_guard_design.md` and the SYSTEM.md untrusted-context notice if the
fidelity channel's behavior is described anywhere agent-facing.
