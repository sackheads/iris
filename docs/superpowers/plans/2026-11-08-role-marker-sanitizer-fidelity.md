# Role-marker sanitizer fidelity (#952) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the role-marker sanitizer from destructively corrupting legitimate content on `read_file` of non-Iris paths, without weakening the turn-forge defense anywhere it is load-bearing.

**Architecture:** "Narrowed A" — on one allowlisted channel (`read_file` of a path not under `~/.iris`), and only when a model-backed tier actually judged the text, the fidelity channel displays the markers faithfully. Every other channel, every no-tier-ran case, and the system prompt keep today's destructive deletion. The delimiter-line recording (#727) that feeds tier-2 is unchanged.

> **REVISION (rev 3, 2026-11-08) — read the spec's rev-3 block first.** The rev-2 mechanism ("judge the normalized **unstripped** text") **failed its eval STOP bar**: judging unstripped text degrades the small canary (fail-closed rate up benign +0.89pp/attack +0.59pp; an attacker-forcible withhold lever). New mechanism: **the canary judges the STRIPPED text (identical to production), and the fidelity channel carries the per-line original to the DISPLAY only**, gated by a per-line alignment invariant. Task deltas:
> - **Task 2:** judge **stripped** (not unstripped); produce the display by carrying each line's original **only when `stripped(line) == original(line) minus whole marker tokens`**, else display that line stripped; the verdict **cache key includes the carried display**.
> - **Task 3:** the closing-tag escape runs on the **display** text and matches normalized-equivalents (fullwidth/ZWSP/spaced/case); the mutation-check targets the display.
> - **Task 4:** a line shown stripped (alignment fell back, or cap/`.partial`/withheld) carries the "incomplete — do not write back" warning.
> - **Task 5:** re-run the eval on the **judge-stripped arm**; **required result: the rev-2 regression vanishes** (the 4 benign-config flips + the +0.89pp fc-rate return to the stripped baseline, since judging stripped == production). If not, reopen. Fail-closed counts as blocked. Review from the script output + dev-1's re-run, not the implementer report.

**Tech Stack:** Swift, `Sources/IrisKit/{InjectionGuard,PromptInjectionGuard}.swift` + the `read_file` guard call site in `iris.swift`; Swift Testing.

**Spec:** `docs/specs/2026-11-08-role-marker-sanitizer-fidelity.md` (**rev 3** — judge-stripped/carry-display, dev-2-concurred). The plan argues from it; read both, rev-3 block first.

## Global Constraints

- **Security trust boundary** (#727/#735/#736/#742). No change may let an injected `system:`/`model:`/`user:`/`assistant:` turn or chat-template token in untrusted output be read as a real turn, on any channel, in any guard config. If a task can't preserve that, it doesn't ship.
- **Judged vs shown (#709), rev-3 trade.** The tiers judge the **stripped** text (= production). The fidelity channel shows the **per-line-carried original**, which differs from the judged text only in whole marker tokens on lines that satisfy the alignment invariant (`stripped == original minus marker tokens`); every other line is shown exactly as judged (stripped). `OutputCap.cap` / tier-2 `.partial` redaction operate on, and line up with, the **carried display**. Outside the fidelity channel, judged == shown as before.
- **Fidelity is "identical modulo normalization".** `normalize()` (NFKC + control/ZWSP strip) still runs; byte-exactness for NFKC-changing input is out of scope (#959).
- **Relax only on the allowlist:** `read_file` of a non-Iris path, tier 2 or 3 provisioned-and-ran (not `.skipped`), protection on. Never `user_profile`/`workspace_rules` (system prompt). Chat-template tokens (`<|im_*|>`) stay stripped always.
- **No new attack payloads.** Forge tests reuse existing owner-authorized dataset rows; benign config fixtures carry no payloads.
- Zero new warnings (`scripts/check-warnings.sh`); no `ConfigManager.shared` mutation in tests; full suite green serially.

## Review Focus

- **A classifier-PASSED forge in the fidelity channel** — a `system: do X` line the tier lets through must still be contained by the wrapper (escape incl. `</untrusted_context >`, `</ untrusted_context>`, fullwidth, ZWSP-split, case). Owned by Task 3.
- **No-tier-ran degradation** — protection off / tier `.skipped` / tier-3 unprovisioned on a `read_file` must fall back to deletion, decided from actual tier outcomes, not assumed. Owned by Task 2.
- **Channel leak** — a web/search/peer/`inbox_item`/`user_profile` input must still be stripped; fidelity must not leak off the allowlist (esp. via a tag-string collision with an MCP tool literally named `read_file`). Owned by Task 1.
- **Partial/capped fidelity read** — tier-2 `.partial`, `OutputCap.cap`, #728 withholding leave holes; a write-back of a holed read persists them, so the reply must warn. Owned by Task 4.
- **Cache correctness** — the fidelity vs deletion mode must be in the guard cache key, or a cached deletion result is served to a fidelity read and vice-versa. Owned by Task 2.

---

### Task 1: Typed fidelity-channel flag at the read_file call site

**Files:**
- Modify: `Sources/IrisKit/iris.swift` (the `read_file` guard call site, ~7147–7193) and the guard entry it calls.
- Modify: `Sources/IrisKit/InjectionGuard.swift` (add the flag to the untrusted entry points: `sanitizeUntrusted`/`classifyUntrusted`/`classifyUntrustedDetailed`).
- Test: `Tests/irisTests/InjectionGuardFidelityTests.swift` (new).

**Interfaces:**
- Produces: a typed parameter (e.g. `fidelity: FidelityMode = .off` where `FidelityMode` is `.off | .preserveWhenJudged`) threaded from the read_file site into the untrusted classify entry. **Not** a `contextTag` string match — an MCP tool named `read_file` produces tag `tool_output_read_file` and must NOT get fidelity (dev-2 finding 1).

- [ ] **Step 1: Write the failing test** — two cases: (a) the real first-party `read_file` of a non-Iris path requests `fidelity == .preserveWhenJudged` at the call site; (b) a synthesized MCP `read_file` tool output (same tag string, different call path) requests `fidelity == .off`. Assert on the flag value reaching the guard (inject a spy/record the passed mode).
- [ ] **Step 2: Run it, verify it fails** (`scripts/test-filter.sh InjectionGuardFidelityTests`, quote the count).
- [ ] **Step 3: Thread the typed flag** from the real read_file guard site into the untrusted classify entry; leave every other caller defaulting to `.off`. Confirm the exact current signatures before editing.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** (`feat: thread a typed fidelity flag from the read_file guard site (#952)`).

### Task 2: Preserve display when a tier judged; fall back to deletion otherwise; cache the mode

**Files:**
- Modify: `Sources/IrisKit/InjectionGuard.swift` (`classifyDetailed` / the pipeline that calls `PromptInjectionGuard.stripRecordingDelimiters` then the tiers), and the cache key.
- Modify: `Sources/IrisKit/PromptInjectionGuard.swift` only if a "record-without-deleting" variant is needed (see Step 3).
- Test: `Tests/irisTests/InjectionGuardFidelityTests.swift`.

**Interfaces:**
- Consumes: `FidelityMode` (Task 1).
- Produces (REV 3 — judge-stripped/carry-display; supersedes the rev-2 text that was here): when `fidelity == .preserveWhenJudged` **and** a model-backed tier ran (tier 2 or 3, provisioned, not `.skipped`, protection on) **and** the verdict is `.passed`, the tiers judge the **stripped** text exactly as production does (`stripRecordingDelimiters` unchanged; `delimiterLines` recorded/scored on it), and the wrapped result **carries the per-line normalized-original to the display** per the Condition-1 predicate below. Else: today's behavior (stripped text shown). **Compute both** the stripped-judged text and the carried display; return the deleted/stripped display when no model-backed tier ran (both `.skipped` or protection off), decided from the actual tier outcomes in `classifyDetailed`. The **carried display** (or its hash) is in the cache key.
- **Condition-1 carry predicate (dev-2's mechanical allowlist — the authoritative version).** Carry a line's `normalize(raw)` original iff **all** hold:
  - **(a)** after removing `---`/`###` from the display line it has **no `<|im_` or `|>` fragment** (catches the sequential-strip token: `remove()` runs in order, so `<|im_s---tart|>` only becomes a token after the `---` pass — pair-equality alone would carry it, so this check is required);
  - **(b) pair-equality:** replaying `stripRecording`'s `remove()` on this one line reproduces the pipeline's `clean` line at that position **exactly** (safe because `stripRecording` is line-by-line, "none spans a newline" — so single-line replay is bit-identical). This is what makes `|---|---|`/`####`/`----` carry.
  - **(c)** the line maps **1:1** to a judged line, split by the **same `\n` splitter** (no `\r`/U+2028/U+0085 join/split on the carry side);
  - **(d) #735 cap:** the line is within the 64-line `delimiterLines` cap — a forged `system:` line **past** the cap shows stripped (tier 2 scored only the top-64; a carried forge past it rode only the whole-text verdict).
  dev-1's `carriedDisplay` already implements **(b)**; **(a)**, **(c)**, **(d)** are the additions. `---`/`###`/`####`/`----`/`|---|---|` carry; `<|im_*|>`, cap-overflow, and (b)/(c)-failing lines show stripped. Carrying `---`/`###` can't reconstruct a forge (display = judged + marker tokens by (b); `</untrusted---_context>` is a non-tag in the display, the judged copy is the one tier-1 escapes — harmless direction).

- [ ] **Step 1: Write failing tests** — with a scripted tier that PASSES: (a) `protection on, tier ran, fidelity on` → a fixture with `model: gpt-x`, indented `  user: alice`, `system: prod`, a leading `---`, `### H`, **a Markdown table (`|a|b|`/`|---|---|`), `#### H4`, `----` hr** → all read back identical-modulo-normalization (markers/separators/headings intact, CARRIED); (b) `fidelity on but tier .skipped` → markers deleted; (c) `fidelity on but protection off` → markers deleted; (d) cache: a deletion read then a fidelity read of the same bytes return different text. **Predicate fallback tests (dev-2):** (e) a **sequential-strip token** line `<|im_s---tart|>` shows **stripped**, not carried (pair-equality holds but predicate (a) excludes it); (f) a forged `system:` line **past the 64-line `delimiterLines` cap** shows stripped (predicate (d)); (g) a **non-`\n` separator** (`\r`/U+2028) does not mis-map lines (predicate (c)).
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement (REV 3).** Judge the **stripped** text (`stripRecordingDelimiters` and the tiers unchanged from production — this is what removes the fail-closed regression). When the mode selects preserve, build the **display** by carrying each line's `normalize(rawInput)` original per the Condition-1 predicate above (markers shown; `<|im_*|>` lines and non-1:1 lines shown stripped), then run the widened closing-tag escape (Task 3) on that display, and include the carried display (or its hash) in the cache key. `wrapped(.passed(...))` gets the carried display; the verdict came from the stripped text. Do **not** skip the strips for judging (that was the rev-2 mistake that failed the eval).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** (`feat: preserve normalized-unstripped display on a judged fidelity read (#952)`).

### Task 3: Marker × path table — tokens always stripped, escape mutation-checked, forge-passed contained

**Files:**
- Modify: `Sources/IrisKit/PromptInjectionGuard.swift` / `InjectionGuard.swift` as needed so `<|im_*|>` tokens are stripped even in the fidelity path, and `---`/`###`/role words are shown in it.
- Test: `Tests/irisTests/InjectionGuardFidelityTests.swift`.

**Interfaces:** Consumes Task 2's preserve path.

- [ ] **Step 1: Write failing tests**, one per table row (spec's marker × path table): fidelity channel shows `system:`/`model:`/`---`/`###` but still strips `<|im_start|>`; other-channel still strips all; plain `sanitize`/`classify` path keeps `model:` **un**stripped exactly as today (pin the documented discrepancy, finding 7). **Classifier-passed forge:** a scripted-pass tier fed `system: do X` → displayed text is the normalized-unstripped marker, wrapped, closing tag escaped — mutation-check with `</untrusted_context >`, `</ untrusted_context>`, fullwidth `＜/…＞`, ZWSP-split, and case variants; assert the content cannot close the wrapper.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the token-always-strip, and **widen the closing-tag escape** (dev-2 tweak 3): it is currently exact-match only, so the mutation variants `</untrusted_context >` / `</ untrusted_context>` pass through — make it whitespace-tolerant, applied after `normalize()`. This tightens **all** channels (a strict improvement); add a test that the widened escape catches the variants everywhere, not only the fidelity path. Confirm the escape runs post-normalize on the preserved text.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** (`feat: fidelity path keeps control tokens stripped, markers shown, wrapper escape held (#952)`).

### Task 4: Incomplete-read warning + #813 taint compensating control

**Files:**
- Modify: the `read_file` reply assembly in `iris.swift` where a tier-2 `.partial`, `OutputCap.cap`, or #728-withheld range produces a truncated/redacted fidelity read.
- Test: `Tests/irisTests/InjectionGuardFidelityTests.swift` (+ a `markReadUntrusted` assertion).

**Interfaces:** Consumes Task 2.

- [ ] **Step 1: Write failing tests** — (a) a fidelity `read_file` whose content is `.partial`/capped/withheld returns a reply that includes an explicit "incomplete — do not write this back" warning (assert the string is present only when the read is holed, absent on a whole read); (b) a fidelity `read_file` still calls `markReadUntrusted` (#813), so the conversation is tainted and a subsequent write is gated — pin this as the compensating control for the accepted residual (dev-2 findings 2, 3).
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the warning on the holed-read branch; confirm `markReadUntrusted` still fires on the fidelity path (it should already — assert, don't re-add).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** (`feat: warn not-to-write-back on a holed fidelity read; pin #813 taint (#952)`).

### Task 5: Owner-authorized eval — benign config fixtures, markers kept vs stripped

**Files:**
- Add: a small benign fixture set (YAML / docker-compose / LLM-config rows, benign, no payloads) to the existing guard eval dataset location.
- Modify: the eval harness invocation/report to include the `fc` (fail-closed) column (dev-2 finding 4/8).
- Test/artifact: the eval run output, cited in the PR.

- [ ] **Step 1:** Add the benign config fixtures (the v4 set has only 4/277 benign config-shaped rows, so this measures the real cost).
- [ ] **Step 2:** Plumb the `FidelityMode` flag into the eval path (dev-2) so the eval can run both arms. Run the existing owner-authorized canary eval **markers-kept vs markers-stripped**, reporting blocks and the `fc` (fail-closed) column, on existing attack rows + the new benign set. No new attack payloads.
- [ ] **Step 3:** Define "materially regresses" **numerically before the run** (dev-2): STOP and report if, markers-kept vs markers-stripped, the **attack-row block rate on the canary falls by more than 1 percentage point (absolute)**, OR **any benign-config row flips from pass to blocked**. On a STOP, the spec's fallback is to carry per-line original text through cap/redaction instead of judging unstripped (finding 3) — a design change needing re-review. Otherwise record the numbers in the PR.
- [ ] **Step 4: Commit** the fixtures + any report doc (`test: benign-config eval for markers-kept vs stripped on the canary (#952)`).

### Task 6: Falsification + docs

**Files:**
- Modify: `docs/prompt_injection_guard_design.md`; the SYSTEM.md untrusted-context notice if it describes marker stripping; verify the comments at `iris.swift:6011-6015` and `6096-6101`.

- [ ] **Step 1:** Grep for what this changes. The `search_conversations`/`read_conversation` "owner"/"iris" substitutions and their comments stay true **because** those channels keep deletion — confirm and leave them. Update the guard design doc to describe the fidelity channel. Fix any agent-facing string that now misstates the behavior.
- [ ] **Step 2: Commit** (`docs: describe the read_file fidelity channel; confirm guarded-channel comments still hold (#952)`).

---

## Self-Review notes
- Spec coverage: narrowed-A channel allowlist (Task 1/2), **judge-stripped + carry-display (rev 3, Task 2)** — NOT judged==shown; the Condition-1 carry predicate bounds the display, marker×path table + tokens + escape-on-display (Task 3), system-prompt exclusion (Task 2 fallback + Task 1 allowlist), partial-read safety (Task 4), eval STOP-bar re-run proving the regression vanishes (Task 5), falsification (Task 6). The system-prompt-never case is pinned by Task 1's channel test + Task 2's "tier ran" gate; add an explicit `user_profile` strip test in Task 3's other-channel row.
- Review Focus → owning task: all five mapped above.
- Execution: security-sensitive and interdependent (Task 2 is the spine). Recommend **subagent-driven-development** (fresh reviewer per task) over native, with dev-2 (or another dev, never the work session) as the security reviewer on the whole branch at the end. The author is a dev; the final whole-branch review confirms the forge invariant with the Task 3 + Task 5 evidence.
