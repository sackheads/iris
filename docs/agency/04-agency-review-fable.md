# Agency (Iris) — Review Notes — Claude Fable 5.1

Cumulative review of `01-agency-draft-scromp.md`, `02-agency-review-rune.md`, `03-agency-review-clomp.md`, checked against the code on `main` as of c3fe65f. The synthesis these notes feed is `agency.md`.

## Bottom line

The three documents agree on more than they disagree, and the disagreements resolve cleanly. What all three miss is that about a third of the epic already exists in the tree, so the first deliverables are behavioural changes to running code, not greenfield.

## What already exists (and what it gets wrong today)

| capability | where | state today |
|---|---|---|
| Cron-like jobs | `schedule_job` tool, `ScheduleManager` | Persisted to disk, interval or five-field cron, `NSWorkspace.didWakeNotification` catch-up. Each missed job fires once after wake, then `nextFireAt` is recomputed from now, so catch-up already coalesces. A fired job becomes a `Scheduled Job Triggered:` system event plus a full model turn **in the conversation that scheduled it, or the selected one**, which is the "pops into the conversation list" complaint verbatim. No run history, no overlap guard, no retry, no budget. `#156`: cannot express "every weekday". |
| Watches | `register_directory_watcher` tool, `WatcherManager`, `FileWatcher` | `FSEventStream` at 1.0 s latency, rules persisted, a rule's instructions fire a turn on change. No quiet window beyond the stream latency, no self-write filter, no breaker. |
| Delivery plumbing | `#173` steer inbox, `#176` turn-ended markers, system-event prefixes, fact-store JIT injection | Four ways to put something in front of the model mid-conversation. Rune is right that a job result must ride one of them. |
| Safety | Vibecop auto-approve, approval queue with continuations, `mainAgentSandboxDefault`, `apple/container` VMs, InjectionGuard tiers on system events and tool output | Everything a background run needs exists; none of it has a "nobody is here" mode. |
| Notifications | `HookManager.fireNotification` | Script hooks only. No `UNUserNotificationCenter`, no `NSStatusItem`, no `IOPMAssertion`, no URL scheme. |
| Persistence | `#163` conversation store (in flight), `#177` cross-conversation search, `#183` sidebar search | The ledger Clomp asks for has a natural home beside the conversation tables. |

Everything below assumes we graduate this code rather than replace it.

## Where the three agree

- Deterministic gate first, model second (Scromp's best idea; Clomp and Rune both keep it).
- Cron and watches are one primitive with different triggers (Rune §3, Clomp §2.4).
- Job results must reach the main conversation without becoming its context (Scromp's requirement, Clomp's "infinite log" is why the naive version fails).
- Phase 1 runs inside the GUI app; a LaunchAgent is a later decision (Clomp's recommendation, Rune's "decide it first" is satisfied by deciding it explicitly).

## Where they differ, and how I would settle it

1. **Substrate.** Rune wants it decided first; Clomp recommends in-app. Both are right: decide it first, and the decision is "in-app, stated as a constraint, with the ledger designed so a helper process can be added without a data-model change". The corp laptop makes LaunchAgents a research task, not a plan item.
2. **Approvals.** Rune offers three policies; Clomp picks fail-closed plus an actionable proposal. Take Clomp's, and make Rune's "deterministic-only" the default profile for new jobs: a job is read-only unless the DM confirmed otherwise when it was created.
3. **Sleep.** Clomp's stampede scenario is already prevented by the recompute-after-fire in `evaluateJobs`; keep the per-job `catchUp` knob anyway (`coalesce` default, `skip`, `replay`) because "run once on wake" is wrong for some jobs. The sleep assertion is new and worth it, capped at the job's timeout.
4. **Delivery.** Rune says pick one existing mechanism; Clomp says ledger plus a rolling briefing plus a forensic tool. These compose: the ledger is the source of truth; the briefing is what the DM's system prompt sees; a result that arrives while the DM is mid-turn rides the `#173` steer inbox; nothing is appended to `messages` except a compact event card.

## What none of the three cover

1. **Budgets, not just breakers.** Clomp caps runs per hour; the real failure is spend. Each job gets a token budget per run and per day, the ledger records tokens per run (the perf harness already knows how), and a job that blows its budget is paused with a card in the DM.
2. **The DM is a conversation with more tools, not a different engine.** Pin it, give it `list_jobs`, `get_job_run`, `search_conversations`, `read_conversation`, inject the rolling briefing, and anchor memory reflection there. That keeps one engine, one turn loop, one set of guards.
3. **Trigger inputs are untrusted.** A watch on `~/Downloads` or a shared drive is an injection vector by construction. Gate outputs and file contents must pass the InjectionGuard tiers before a model sees them, the same way system events do today. Job definitions written by the model for itself need Vibecop review when they mutate anything.
4. **Headless drivability.** The eval harness (`--perf`, `--bench`, `ScenarioRunner`) exists so nothing lands unmeasured. Background runs need `iris --run-job <id>` so the gate's false-positive rate and a job's token cost can be measured before the job is trusted.
5. **Observability answers Rune §4 directly.** `/jobs` in the DM, a run log view, failures in the briefing, and a daily digest that is itself a deterministic job. "Failing silently for a week" becomes impossible without anyone remembering to look.
6. **Migration of what exists.** `ScheduledJob` and `WatcherRule` are persisted in their own files; the unified trigger model has to import both. Small, but it is a deliverable.
7. **Time.** Store a timezone per job and adopt a real cron subset (lists, ranges, step values) so `#156` closes properly instead of with five jobs.

## On the decompositions

Clomp's five phases are the right pieces in slightly the wrong order. The ledger must exist before the scheduler rework, because the rework's first job is to stop writing into `messages` and start writing into the ledger. The order in `agency.md` is: decide and document the two policies; ledger and delivery; graduate the scheduler and watcher onto one trigger model; the pinned DM; native surfaces.
