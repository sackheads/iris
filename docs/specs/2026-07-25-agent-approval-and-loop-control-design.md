# Agent Approval & Loop-Control Overhaul

## Motivation

Testing the dual-layer sandbox (Test D) surfaced a hang: a subagent's sandboxed `run_command`
requested approval, the request never reached the user, and the subagent blocked forever. The
stopgap (`6935d8b`) bypassed approval for **any** sandboxed command — including a sandboxed main
agent — which is a real safety hole, not a fix.

Investigation found three structural defects, plus an existing tracked bug (issue #16, "turn
limits / loop detection") with ~100% overlap:

1. **Approval is a single global slot** (`AppState.pendingApproval`). A second concurrent request
   overwrites the first and leaks its continuation → permanent hang. No queue, no origin label,
   no timeout on Vibecop.
2. **Subagent tasks are never cancelled.** `SubagentManager`'s 5-minute loop only stops the
   *parent* from waiting; the subagent's `IrisEngine` task keeps running (or stays blocked on the
   approval continuation) indefinitely — leaking tokens and a live sandbox container.
3. **Goal loops can run away** (issue #16). The existing cap force-completes at a hardcoded 100
   iterations with a "Subagent failed" message (wrong for the main agent), no summary, and no
   detection of "did the same thing N times."

This spec fixes all of it as one cohesive change in two parts: **(A) approval routing** and
**(B) loop control & agent lifecycle**. Part A lands first because Part B's cancellation depends
on Part A's `denyPendingApprovals`.

**Out of scope:** the sandbox mechanism (Piece 1) and routing policy (Piece 2a) are unchanged;
this is about *approval* and *termination*, not *where* commands run.

## Part A — Approval routing

### A1. Revert the blanket bypass
`iris.swift` `executeFunctionCall`: `if needsApproval && !useSandbox` → `if needsApproval`.
Sandboxed `run_command` goes through the approval flow again.

### A2. Approval queue (fixes the clobber)
Replace `AppState.pendingApproval: ToolApprovalRequest?` with `pendingApprovals:
[ToolApprovalRequest]`.
- `requestApproval(...)` appends a request (with its own continuation) to the queue and awaits it.
- `resolveApproval(_:)` resolves the **head** request and removes it, revealing the next.
- Concurrent requests from multiple subagents (or subagent + main) stack safely; no continuation
  is ever leaked by being overwritten.
- **Isolation:** `AppState` is `@MainActor`, so all queue mutations (append/remove) and every
  continuation `resume` in `requestApproval`, `resolveApproval`, and `denyPendingApprovals` run on
  the main actor. Background subagent tasks reach these methods via `await` (an actor hop), so
  concurrent calls are serialized — no locks needed, and a continuation is resumed exactly once.

### A3. Origin labeling + reliable surfacing
`ToolApprovalRequest` gains `id: UUID`, `conversationId: UUID?`, and `origin: String`.
- The engine supplies `origin`: `.main` → `"Main agent"`; `.subagent` → `"Subagent (<role>)"`.
  `IrisEngine` gains `let roleLabel: String?` (set by `SubagentManager` to the subagent's role;
  nil for the main agent).
- The `ApprovalBannerView` shows the head request's `origin` and details, e.g. *"Subagent
  (engineer) wants to run: `uname -a`"*, and renders as a global overlay so a background
  subagent's request is never missed. A small "N more pending" affordance is shown when the queue
  depth > 1.

### A4. Vibecop timeout (never hang the turn)
Wrap `VibecopService.evaluateAction` in a timeout of `ConfigManager.vibecopTimeoutSeconds`
(default 5). On timeout or error, fail **open to the user prompt** (treated as ESCALATE) — the
turn never blocks on a wedged model call. (Observed Vibecop latency today: ~1.5–3.4s, so 5s gives
headroom; configurable if a slower model needs more.)

**Cancellation on timeout:** implement the timeout with a task group that cancels the losing
branch, and best-effort-cancels the underlying `evaluateAction` (which should observe
`Task.isCancelled`). Note the honest limitation: a native local-inference call already in flight
may not be interruptible mid-token and could run to completion in the background — but its result
is **abandoned** (we've already escalated), so it cannot resume the turn or leak a continuation;
the only cost is some wasted compute on the losing call.

### A5. Sandbox-aware Vibecop
`evaluateAction` gains `inSandbox: Bool` (threaded from the engine's `useSandbox`). When true, the
Vibecop prompt is told the command runs in a disposable, network-capable Linux VM isolated from
the host, so it should **auto-approve routine in-VM commands** (build/test/inspect/package
installs) and **escalate only genuinely risky ones** — new-host network egress, container-escape
or privilege attempts, or anything touching host-bridged resources. This gives low friction for
in-VM work while sketchy actions still bubble up.

### A6. `denyPendingApprovals(for:)`
`AppState.denyPendingApprovals(for conversationId: UUID)` resolves-false and removes every queued
request whose `conversationId` matches. This is how Part B unsticks a subagent that is blocked on
an approval continuation when it is cancelled/timed-out.

## Part B — Loop control & agent lifecycle (issue #16 + subagent-stuck)

### B1. Configurable turn cap
Replace the hardcoded `> 100` in the goal auto-reprompt with `ConfigManager.maxGoalIterations`
(default **50**). Applies to every goal loop — main agent, self-defined goals, and subagents.
(Since #399 a subagent has its own cap, `maxSubagentIterations`, default 10, which ends it `failed` without a summary turn.)

### B2. Loop detection
The engine keeps a short per-conversation history of executed tool-call signatures
(`"<name>|<stable-json-of-args>"`). If the last `ConfigManager.loopDetectionThreshold` (default
**5**) signatures are identical, the agent is stuck repeating itself → trigger a **soft stop**
early (before the turn cap). The history is cleared on `goal_complete`, on a new user turn, and
on stop.

**Deterministic signatures (required):** the args serialization MUST be canonical so that
identical arguments always produce identical strings. Swift dictionaries are unordered, so the
signature is built with sorted keys — `JSONEncoder` with `.outputFormatting = [.sortedKeys]`
(or `JSONSerialization` with `.sortedKeys`). Without this, key-ordering jitter would make the
same repeated call look different and silently defeat detection.

### B3. Summarize + hand back (split by how it stopped)
When a goal loop stops for a control reason, produce a summary and hand back — never silently
force-complete:

- **Soft stop** (turn cap reached, or loop detected; the agent is responsive): clear the goal
  (so no re-reprompt), then run **one** final model turn with a summarization instruction ("You've
  reached your working limit / appear to be repeating the same step. Summarize what you
  accomplished and what is blocking you, then stop."). Surface the result:
  - main agent / self-goal → post the summary and await the user;
  - subagent → return the summary to the parent via `onSubagentComplete`.
- **Hard stop** (wall-clock timeout or explicit user cancel; the agent may be *blocked*): build a
  **deterministic** summary with no LLM call ("Cancelled after timeout. Last actions: …" from the
  recent-signature history), to avoid spending tokens on a wedged agent.

All messages are principal-correct — no "Subagent failed" text for the main agent.

### B4. Subagent task cancellation & teardown
`SubagentManager.runSubagent` stores the `Task` running `engine.processInput`. When the timeout
fires (or the subagent is otherwise cancelled), it performs a full teardown, in order:
1. `engineTask.cancel()` (the engine loop bails at its next `Task.isCancelled` boundary);
2. `await appState.denyPendingApprovals(for: subagentId)` (A6 — unsticks an approval-blocked
   subagent immediately, since a blocked continuation never reaches a turn boundary);
3. `await engine.cancelReprompt(for: subagentId)`;
4. `await SandboxSessionManager.shared.endSession(subagentId)` (free the container);
5. `clearGoal(for: subagentId)`;
6. return the deterministic hard-stop summary (B3) to the parent.

This is the fix for "subagents getting stuck forever."

## Configuration

New `ConfigManager` values (all persisted; surfaced in Settings under a new "Agent limits"
group):
- `maxGoalIterations: Int` — default 50.
- `loopDetectionThreshold: Int` — default 5.
- `vibecopTimeoutSeconds: Int` — default 5.

## Testing

Unit-testable pure logic (the priority):
- **Approval queue** (`AppState` or an extracted helper): enqueue N requests → each resolves
  independently; `resolveApproval` resolves FIFO head; `denyPendingApprovals(for:)` resolves-false
  only the matching conversation's requests and leaves others intact; no continuation leaked.
- **Loop detector**: `threshold` identical consecutive signatures trips; a differing signature
  resets the run; distinct calls never trip. Signature determinism: the same tool name + args
  supplied with different dictionary insertion order produces the **same** signature (guards the
  Edge-2 sorted-keys requirement).
- **Vibecop timeout wrapper**: a call exceeding the timeout resolves as ESCALATE (fail-open), not
  a throw that blocks; a fast call passes its real decision through.
- **Turn-cap decision**: iteration ≥ cap → stop; below → continue.

Integration (build + manual): the banner shows subagent origin and queues multiple requests; a
timed-out subagent is cancelled, its approvals denied, its container removed, and a summary
returned to the parent; a runaway goal loop stops at the cap / on repetition with a summary.

## Rollout

Additive and self-contained. Approval behavior returns to prompting (the bypass is reverted),
now correct under concurrency and with origin context. Goal loops gain a lower default cap (50),
loop detection, and graceful summaries. No change to sandbox routing, `read_file`/`write_file`,
or the guardrail *policy* (Vibecop's verdicts) beyond the added timeout and sandbox-awareness.
