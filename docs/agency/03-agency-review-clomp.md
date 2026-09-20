# Architectural Review: Iris Gains Agency

**Reviewer:** Clomp (autonomous Hermes agent, host `mink`)  
**Target:** `/shared/agents/scromp/inbox/agency.md`  
**Scope:** Architecture, concurrency, lifecycle, and operational guardrails for background agency in Iris (macOS SwiftUI harness).  
**Date:** 2026-09-18  

---

## 1. Executive Summary

The transition from a reactive chat/goal harness to an autonomous background agent represents a fundamental architectural shift. The core intuition in `agency.md`—prioritizing deterministic, LLM-free gating before burning tokens, and eliminating the amnesia between cron runs and the user's conversational interface—is spot-on.

However, moving background agency onto a **macOS laptop** exposes constraints and failure modes that headless Linux server environments (like Hermes on `mink`/`diffuser`) never encounter. This review details the missing architectural requirements across five domains:

1. **Laptop Lifecycle & Power Management** (sleep/wake, tick coalescing, assertions).
2. **Context Hygiene in the Main DM** (avoiding context window pollution and recency bias).
3. **Headless Execution & Approvals** (fail-closed semantics and actionable proposals).
4. **Unified Event Architecture: Cron + Watches** (debouncing, self-trigger recursion shields).
5. **Native macOS Surface Integrations** (`UserNotifications`, `NSStatusItem`, deep linking).

---

## 2. Detailed Findings & Missing Requirements

### 2.1 The Laptop Lifecycle Problem (Sleep, Wake, and Stampedes)

Hermes assumes continuous server uptime. Iris runs on a MacBook that sleeps in backpacks, drops Wi-Fi, and operates across discontinuous time.

* **Missed Tick Stampedes:** If a cron job is scheduled for `every 30m` and the laptop is asleep from Friday 6 PM to Monday 9 AM, an un-gated timer will detect 138 missed ticks on wake and attempt to fire 138 concurrent sessions.
  * *Requirement:* Explicit catch-up semantics must be defined per job: `coalesce` (collapse all missed ticks into a single catch-up run), `skip` (advance next trigger time to `now + interval`), or `replay` (rare, only for non-idempotent ledger updates). Default must be `coalesce` or `skip`.
* **Sleep Assertions (`IOPMAssertion`):** When Iris is executing a background job or active tool command, macOS will still sleep the system on idle or lid close. A background process killed or suspended mid-git operation, lock acquisition, or file write risks state corruption.
  * *Requirement:* Background execution must acquire an `IOPMAssertionCreateWithName` (`kIOPMAssertionTypePreventUserIdleSystemSleep`) on task start and release it on completion or timeout.
* **Process Boundary (`launchd` vs. GUI App):** In a standard macOS app lifecycle, `Cmd+Q` terminates the process and all scheduled timers/watches cease.
  * *Decision Required:* Is background agency strictly bound to the active lifespan of the Iris SwiftUI process, or does Iris separate into a GUI client and a headless `launchd` LaunchAgent helper daemon? 
  * *Recommendation:* Keep it inside the GUI app for Phase 1 to avoid IPC/auth complexity, but explicitly document that background agency requires the app to remain running (minimized or backgrounded).

---

### 2.2 The Main DM Context Trap (Avoiding the "Infinite Log")

`agency.md` states:
> *"The 'Main' Iris session is aware of cron job execution and the results of them... I want to be able to discuss the cron job result without having to paste it back fresh."*

Dumping raw execution output from recurring background jobs directly into the Main DM message array (`ChatMessage`) creates a severe context window trap:
1. **Token Exhaustion:** If jobs fire every 15–30 minutes, the conversation context will accumulate hundreds of execution logs in days, drastically increasing per-turn token spend and latency.
2. **Induced Amnesia:** Background chatter will force early context compaction, evicting the actual conversational history and user instructions you cared about.
3. **Recency Fixation:** Large language models exhibit recency bias; inundating context with background telemetry causes the model to draw hallucinated associations between new conversational prompts and unrelated background checks.

#### Architectural Solution:
* **The Background Event Ledger:** Store cron and watch outputs in a dedicated relational or structured store (e.g. SQLite execution table), not as raw messages in `Conversation.messages`.
* **The Rolling Briefing (System Prompt Injection):** Inject a compact, structured `<recent_activity>` summary block into the Main DM’s assembled system prompt on each turn, capped to the last 3–5 notable events (timestamp, job name, status, 1-line outcome).
* **Forensic Recall Tools:** When you ask Main Iris, *"What happened with the PR sweep this morning?"*, Iris should invoke a tool—e.g. `get_job_run(job_id:, run_id:)` or query the cross-conversation search store (#177)—to load the full execution log on demand.
* **UI Artifacts vs. Model Context:** Display alerts delivered to the Main DM as distinct, collapsible UI elements (event cards or system pills) rather than standard assistant chat bubbles.

---

### 2.3 Headless Execution & The Approval Deadlock

`agency.md` asks:
> *"What to do about things the jobs try to do that might invoke approvals?"*

In interactive conversations, the engine can block and await user input via the Vibecop / Guardian approval modal. In an autonomous background job:

* **Strict Fail-Closed Rule:** A headless task must **never block synchronously** on an approval. Blocking background threads leads to worker starvation and hangs the scheduler.
* **Actionable Proposal Escalation:** If a tool call triggers an `approval_required` barrier, the tool must fail immediately with an explicit status. The job's agent session should catch this and formulate an **Actionable Proposal**:
  * The job posts a structured proposal card to the designated destination (Main DM).
  * Example: *"Cron job `pr-sweep` wants to run `git push origin main`. Blocked by approval policy. [Approve & Run] [Dismiss]"*.
  * Clicking "Approve" dispatches the operation in a tracked foreground turn.
* **Permission Profiles & Sandboxing:** Background jobs should declare their privilege profile:
  * `read_only` (inspection, diffing, reporting): Allowed autonomous execution.
  * `mutating`: Bounded strictly to the `apple/container` sandbox runtime unless explicitly marked with pre-approved execution waivers.

---

### 2.4 Unifying Cron & Watches (Trigger → Gate → Runner)

Cron and Watches should not be built as separate runtime architectures. They are two trigger adapters that feed into a single unified execution pipeline:

```
[Timer Trigger (Cron)]    ──┐
                            ├─► [Deterministic Gate (LLM-Free)] ──(Signal/Diff?)──► [IrisEngine Session] ──► [Delivery & Ledger]
[Reactive Trigger (Watch)] ─┘
```

#### Critical Watch Mechanics to Add:
* **FSEvent Debouncing & Quiet Windows:** Filesystem events arrive in rapid bursts (atomic writes create temp files, write content, update metadata, and rename). An FSEvent watcher on a directory will fire 3–8 times for a single file save.
  * *Requirement:* All filesystem watches must implement a configurable debounce window (e.g., 2–5 seconds of silence) before passing the event downstream.
* **Self-Trigger Recursion Shield (The Infinite Loop):** If a watch monitors `~/Documents/Notes` and Iris’s agent modifies `~/Documents/Notes/summary.md`, the write trips the watch, which spawns Iris, which writes to notes, triggering an infinite loop and burning API budget.
  * *Requirement:* Maintain an active execution write lock or filter out filesystem events authored by Iris’s own PID / internal writes.
* **Circuit Breakers:** Every cron and watch must enforce a hard execution ceiling (e.g., maximum 5 runs per hour, or automatic backoff if an agent session fails repeatedly).

---

### 2.5 Native macOS Surface Integrations

Since Iris is a native Swift application on macOS, background agency should leverage macOS-native APIs rather than behaving like a CLI daemon:

* **Actionable User Notifications (`UNUserNotificationCenter`):** When a watch or cron produces a high-priority finding, surface a native macOS notification banner with category actions (e.g., "View in Main Chat", "Dismiss", "Run Fix").
* **Menu Bar Status (`NSStatusItem`):** Provide an ambient status item in the macOS menu bar:
  * Visual indicator of background health (Idle, Running Job, Action Required).
  * Dropdown listing recent background executions and quick-access pause/resume toggles.
* **Custom URL Scheme (`iris://`):** Register an `iris://run-job/<id>` URL scheme to allow macOS Shortcuts, Raycast commands, or local shell hooks to trigger Iris agent workflows externally.

---

## 3. Recommended Epic Decomposition

To execute this smoothly, break the epic into five sequential deliverables:

1. **Phase 1: The Background Task Scheduler & Gate Engine**
   - In-memory scheduler with tick coalescing and sleep awareness.
   - Deterministic gating engine: scripts/commands run locally; agent session only spawns on non-zero diff or explicit signal.
   - Fail-closed approval handling with structured output.

2. **Phase 2: The Background Event Ledger & Main DM Integration**
   - Database/ledger for job run history and session logs.
   - System prompt assembly injection (`<recent_activity>` rolling brief).
   - Forensic tool declarations for conversational querying of past job runs.

3. **Phase 3: Main DM Pinned Persistence (Follow-up to #177)**
   - Pinned root conversation with cross-conversation search and inspection capabilities.
   - Visual separation of background event cards vs. conversational message bubbles.

4. **Phase 4: Reactive Watches Engine (FSEvents & HTTP Checks)**
   - FSEvent stream integration with debouncing and quiet-period coalescing.
   - PID/write-lock recursion shield to prevent self-trigger cascades.

5. **Phase 5: Native macOS Enhancements & UI**
   - Scheduled Jobs management view in Iris settings.
   - `UNUserNotificationCenter` integration for background alerts.
   - Optional menu bar (`NSStatusItem`) status indicator.
