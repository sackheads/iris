# Structured Inner-Loop Result (slice B2) — Design

* **Issues**: [#13](https://github.com/bnaylor/iris/issues/13) (inner/outer loop semantics) — the **inner-loop-result half**. Builds on merged **slice B1** ([2026-08-01-goal-checkpoint-ladder.md](2026-08-01-goal-checkpoint-ladder.md)), **slice A** ([2026-07-28-goal-contract.md](2026-07-28-goal-contract.md)), and **slice C** ([2026-07-29-goal-drift-evaluator.md](2026-07-29-goal-drift-evaluator.md)).
* **Date**: 2026-08-02
* **Status**: Implemented

## 1. Overview

Slice B1 gave the *outer* loop a checkpoint ladder. The *inner* loop — a subagent dispatched by `SubagentManager.runSubagent` — still returns an opaque `String` to its parent. The parent main-agent cannot reliably tell success from failure, cannot see what the subagent touched, and can misread a timeout message as a completed result.

B2 replaces that string with a structured, versioned **`SubagentResult`**. Its contents are split by **trust**, exactly as B1's checkpoint pause splits self-report from verdict: **hard facts** the harness knows for certain, and an explicitly **unverified** self-report the subagent authored. The parent still receives a readable prose block (LLMs branch fine on prose, and it keeps token cost sane); the struct is persisted on the subagent `Conversation` for the UI and for later slices to consume.

This is the **out-envelope** of the outer/inner context boundary that #13 calls for. The *in-envelope* (a bounded-unit contract handed to the subagent) is slice B3; wiring a B1 checkpoint to delegate its milestone to a subagent is slice B4 (§9).

## 2. Scope of this slice (B2)

B2 **structures what already flows back** from a subagent and adds a cheap, honest record of files it wrote. It does **not** give the subagent a definition-of-done and does **not** grade it.

**Honesty boundary (stated up front).** The `summary` field is the subagent's own words — the *same context that did the work* — and is therefore marked **unverified**, reusing A/B1's honesty marking. B2 introduces **no** trusted per-criterion verdict for the inner loop: without a contract there is nothing to grade against, and a self-authored per-goal status is exactly the self-authored-target problem the C evaluator exists to distrust. Trust for the inner loop arrives in B3 with a gradeable unit contract.

**Explicitly deferred (deliberate, not silent omissions):**
- **Per-item self-report + gradeable unit contract → slice B3.** B2's self-report is a single unverified `summary` string plus hard facts. A structured per-criterion status for the inner loop requires a contract to be meaningful, which is B3.
- **Checkpoint→milestone delegation → slice B4.** A B1 checkpoint handing its milestone to a bounded subagent (B3 contract in → B2 result out) is the B-arc capstone; B2 touches neither the ladder nor `reach_checkpoint`.
- **A complete filesystem diff → out of scope, by construction.** The files ledger records `write_file` calls only. Files mutated by `run_command` (compilers, `git`, `mv`, editors) are invisible to the harness and are **not** claimed. The field is named and documented as "files written via `write_file`," not "all files changed."

## 3. Data model

Two new types, plus one `decodeIfPresent`-defaulted field on `Conversation`:

```swift
enum SubagentTerminalStatus: String, Codable, Sendable, Equatable {
    case completed   // goal_complete was called by the subagent
    case failed      // LLM/engine error ended the run
    case timedOut    // the 5-minute poll cap in SubagentManager fired
    case cancelled   // stop/cancel path ended the run
}

struct SubagentResult: Codable, Sendable, Equatable {
    var schemaVersion = 1
    var role: String
    var status: SubagentTerminalStatus
    var calledGoalComplete: Bool     // true only via the real goal_complete termination site
    var summary: String              // UNVERIFIED self-report — the subagent's own words
    var filesWritten: [String]       // deduped write_file paths, workspace-relative when possible
    var startedAt: Date
    var endedAt: Date
}
```

`Conversation` gains:

```swift
var subagentResult: SubagentResult? = nil
```

added to `CodingKeys` and decoded with `decodeIfPresent` → `nil`. **This is required for data safety**: `Conversation` has a custom `init(from:)`, and a new field decoded without `decodeIfPresent` makes a missing key throw and wipes every persisted conversation on load. (Recorded hazard: a defaulted field on this Codable dropped all conversations once before.)

## 4. Producing the result — the four termination sites

Today `AppState.onSubagentComplete` is `[UUID: @Sendable (String) -> Void]`, invoked from four places, each of which already knows the terminal condition. B2 changes the callback to carry a small **termination signal** — `status`, `summary`, and `calledGoalComplete` — **not** the full struct:

| Site | Status | Notes |
|---|---|---|
| `iris.swift:860` real `goal_complete` | `.completed` | `calledGoalComplete = true`; `summary` = the model's summary |
| `iris.swift:679` LLM/engine error | `.failed` | `summary` = error description |
| `iris.swift:119` cancel / stop | `.cancelled` | `summary` = stop reason |
| `SubagentManager.swift:89` poll cap | `.timedOut` | `summary` = timeout message |

**`SubagentManager` is the single assembly point.** It already owns `role`, the start time, and the polling loop that awaits the callback. It combines the termination signal with `role` + timing + the drained write-ledger (§5) into the final `SubagentResult`, persists it on the subagent conversation, renders the prose (§6), and returns the prose. The four sites stay minimal; construction is centralized in one place.

**Main-agent `goal_complete` is untouched.** `onSubagentComplete` is registered only for subagent conversations (by `SubagentManager`). For a main-agent `goal_complete`, no callback is registered, so `iris.swift:860` remains a no-op for that path exactly as today — no outer-loop behavior change.

## 5. Files-written ledger

A per-conversation ledger on `AppState`:

```swift
var subagentWriteLedger: [UUID: [String]] = [:]
```

Appended when a `write_file` **succeeds** for a **subagent** conversation. `ToolExecutor.execute(...)` already receives `conversationId`, so the write path can record against it; scoping to subagent conversations keeps the main agent's writes from accumulating. `SubagentManager` drains the ledger into `filesWritten` (deduped, preserving first-write order) at termination and clears the entry in `finishSession`.

Scope is honest by construction (§2): only `write_file` is recorded, never `run_command` side effects.

## 6. What the parent sees

The tool handler at `iris.swift:830` (`result = await SubagentManager.shared.runSubagent(...)`) still receives a `String`, but `runSubagent` now renders the struct into a readable block:

```
Subagent 'engineer' finished — status: completed (goal_complete called).
Summary: <summary>
Files written (3): Sources/A.swift, Sources/B.swift, Tests/AT.swift
```

For `failed` / `timedOut` / `cancelled`, the status line makes the failure **explicit**. This fixes a current sharp edge: a timeout returns a plain sentence the parent model can misread as a successful result. The struct is the programmatic artifact; the prose is the branch surface for the LLM.

**Background variant.** `run_subagent` also has a background form (`iris.swift:828`) that returns immediately and posts a completion System Event later. That event renders the **same** structured prose, so the two dispatch paths report identically. This is the one spot B2 touches a second code path.

## 7. Error handling & edge cases

- **Timeout** → `.timedOut`, `calledGoalComplete = false`; whatever files were written before the cap are still reported.
- **LLM error mid-run** → `.failed`; `filesWritten` reflects writes up to the failure.
- **Cancel/stop** → `.cancelled`; partial `filesWritten` preserved.
- **Subagent writes nothing** → `filesWritten == []` (not absent); prose omits the files line.
- **Legacy conversation on disk** (no `subagentResult` key) → decodes to `nil`, no wipe (§3).
- **Main-agent conversation** → never carries a `subagentResult`; the ledger scopes to subagents.

## 8. Testing

**Pure / unit-testable:**
- `SubagentResult` / `SubagentTerminalStatus` Codable round-trip.
- Backwards compat: a `Conversation` encoded without `subagentResult` decodes to `nil` and does **not** wipe other conversations.
- Prose rendering: a `failed` / `timedOut` result renders a status line that literally states failed / timed out (guards the misread-as-success bug); a `completed` result with files renders the files line; zero files omits it.

**Handler / loop (driven by `ScriptedLLMClient` + `SubagentManager`, as existing subagent/goal tests are):**
- Scripted `goal_complete` in a subagent → `status == .completed`, `calledGoalComplete == true`, `summary` carried, result persisted on the subagent conversation.
- Forced poll-cap path → `.timedOut`.
- Cancel path → `.cancelled`.
- Injected LLM error → `.failed`.
- Ledger: a subagent that `write_file`s two paths yields `filesWritten` equal to those two, deduped; the ledger entry is cleared after `finishSession`.
- Regression: a main-agent `goal_complete` still clears the goal and fires its background grade with no `onSubagentComplete` invocation (no registered callback).

## 9. Interaction constraints (fixed, not a blank slate)

- **`goal_complete` semantics are unchanged** — still the sole terminal path that clears the goal, self-reports, and (for the main agent) fires the background C grade + skill-check reflection. B2 only restructures what a *subagent's* completion delivers to its parent.
- **B1's checkpoint ladder is untouched** — `reach_checkpoint`, the pause, and the oracle are not modified. Subagents carry no `goalContract`, so `hasLadder` is false for them regardless.
- **The C evaluator is not invoked for the inner loop in B2** — no contract exists to grade. Grading the inner loop is B3.
- **`ToolExecutor` and the tool set are unchanged in shape** — the only addition is a write-ledger side-record on successful `write_file` for subagent conversations.

## 10. The larger arc (where B2 sits)

Remaining B-arc, in dependency order:
- **B3 — bounded-unit contract for the inner loop:** hand the subagent its own scoped `GoalContract` (a unit definition-of-done) so its completion is gradeable by the C evaluator (reused unmodified). The `SubagentResult` gains a *verified* verdict section beside the unverified `summary`. Depends on B2.
- **B4 — checkpoint delegation (capstone):** a B1 checkpoint may hand its milestone to a bounded subagent (B3 contract in → B2 result out); the outer loop grades the projection and resumes the ladder. Depends on B1 + B2 + B3.
- **D — deterministic done-gates**, **E — the ratchet**, **F — ground-truth progress view** — independent, per the slice-A roadmap.
