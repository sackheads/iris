# Agency (Iris) — Review Notes — Rune

Bottom line: **decide the execution substrate and the unattended-action safety policy first** — the rest is detail you already have the instincts for.

## 1. Execution substrate — the whole ballgame, and it's not addressed

"Same as Hermes" hides the hard part. Hermes cron works because the gateway is an always-on daemon; Iris is a foreground macOS app, so cron jobs and watches only fire while it's open (and not asleep/napped).

Decide what's actually running before anything else:

- a LaunchAgent / helper daemon, or
- `BGTaskScheduler` (throttled and unreliable for user-defined schedules), or
- "app must be open" as an explicit, accepted constraint.

And note Iris runs on a corp-locked laptop — LaunchAgents/helpers may be MDM-restricted, which narrows the options further. Every downstream decision (where state lives, how approvals work, how the main session gets notified) forks on this one answer. This is the question to resolve before the other two arcs, not in parallel with them.

## 2. The unattended-action safety model is the core risk, not a footnote

"what about approvals?" is listed as an open question, but it's the central design problem. A background job running tools with no human present is the difference between "assistant" and "unattended actor."

Pick a concrete policy, not a note:

- **scoped per-job auto-approve** — a Guardian-style allowlist of what a given job may do unattended;
- **defer-to-main-session** — a pending approval surfaces in the pinned conversation and blocks until answered;
- **deterministic-only jobs** — no LLM, no mutating tools.

And spell out the failure side: what happens to an un-approved action — fail, retry, defer, dead-letter?

## 3. Cron and watches are the same primitive — unreconciled

Both are "trigger → (optional condition) → action." A "script that checks HEAD" is literally a cron job with a fast cadence; only FSEvents is genuinely event-driven, and it has its own constraints (directory-granularity, not file-level; coalesces/drops under load; needs a live process).

Define one scheduler substrate with trigger types — time / fs-event / poll — rather than two arcs. Otherwise the daemon, the queue, the session-spawn logic, and the notification path all get built twice.

## 4. Failure & concurrency semantics are missing

Nothing on:

- **overlapping runs** — a job fires while its previous run is still going (skip / queue / kill?);
- **retry / backoff / dead-letter** on failure;
- **"how do I discover a job has been silently failing for a week"** — the "main session sees results" story covers only the happy path;
- **idempotency / loop-guard** — a watch that fires on its own writes will spin.

## 5. Relationship to /goal and the existing model is undefined

A cron job doing multi-step work is a goal-like thing. Is a cron job just "a scheduled goal"? Can a job run a goal loop / delegate to a subagent?

"Main conversation reads other conversations" needs a concrete tool + scope:

- does it read subagent scratch conversations (ephemeral — should not)?
- does it read the UI `messages` or the raw `history`?

On "the main session is aware of a job result" — the plumbing already exists (system-event prefixes, #173 steer inbox, #176 turn markers, the fact store's JIT injection). Specify *which* of those the result-notification rides on, or it'll get re-invented as a fourth mechanism.

## Smaller

- No **non-goals** section — agency needs explicit boundaries (what Iris must never do autonomously).
- The token-economics risk isn't "one check" — it's **watches firing too often** and chatty jobs.
