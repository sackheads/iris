# Agency deliverable 5b: The main conversation

Status: **proposed** (2026-10-01). Deliverable 5b of #187. 5a (`2026-09-30-agency-cacheable-prompts.md`, #312, #320) made prompts cacheable and added the per-turn `<turn_context>` block that this deliverable's briefing rides. Three settings 5a's measurements raised apply to every conversation, not just this one: tool declaration policy on Anthropic (invariant 6), the budget defaults, and the cache TTL. They are **not** decided here; they get their own short spec, 5c.

The pinned conversation exists already: deliverable 2 created it as **Iris Activity**, where job event cards land (`AppState.activityConversationId()`, `docs/jobs.md` "Event cards and the Iris Activity conversation"). 5b makes it the conversation the owner talks to every day. It knows what background work has been doing, it can look back through other chats, and it stays cheap to keep forever.

## 0. Decided

Each decision names its default and why; the cost of being wrong is what a reviewer should weigh.

1. **One pinned conversation, named "Iris".** `activityConversationId()` stays the single way to find or create it, and the pin is still `isPinned`. The default title becomes **Iris**. On launch, an existing pinned conversation still titled exactly "Iris Activity" is retitled; one the owner renamed keeps its name. *Why:* it is now the main conversation, not a log. *Cost if wrong:* a title.
2. **Exemptions.** The pinned conversation is never auto-renamed: both the 3-message rename trigger and the `rename_conversation` tool skip it, and so does `/rename`'s model path. `/clear` stays refused. It **does** auto-reflect, at the same 30-message threshold as any conversation, and also at `/new` (decision 4). *Why:* the owner expects meaningful learning to happen there. *Cost if wrong:* one reflection turn per 30 messages.
3. **The briefing rides 5a's turn-context block.** On pinned-conversation turns only, the turn context gains a `# Recent Activity` section, built fresh from the job ledger each turn:
   - every unacknowledged failure, and every paused job;
   - then the most recent notable runs, failures first, up to **five lines in total beyond the pinned items**.
   
   One line each: job name, status, a short outcome, the run id. The section is omitted when there is nothing to say, so a quiet day adds zero bytes. *Why:* 5a measured that per-turn content in this block costs about one turn's tail, not a re-write, and the agency epic's "Decided in review" fixed the cap ("five recent events, plus every unacknowledged failure and paused job"). *Cost if wrong:* a longer per-turn block when many things fail at once, which is the moment it should be long.
4. **`/new` in the pinned conversation rotates it.** In order:
   1. run one reflection pass in place, so durable learning reaches memory before the history leaves context;
   2. write a summary of at most ~400 tokens (decisions made, open threads, follow-ups the owner asked for). One easy-tier call; the result passes the injection guard;
   3. archive the old conversation (`/archive`'s mechanism). It stays searchable and readable, and is retitled "Iris — ‹first date›–‹last date›";
   4. create a fresh pinned conversation whose first entry is the summary, and move the pin.
   
   If the summary call fails, the rotation still happens, and the new conversation's first entry says no summary was produced and names the archived conversation. Elsewhere `/new` keeps today's behaviour (a new tab). *Why:* the owner chose "archive, but summarize". Archiving rather than trimming keeps the transcript reachable through `read_conversation`. *Cost if wrong:* one model call per rotation.
5. **Tools, pinned conversation only, declared on every turn there.**
   - `search_conversations(query, limit?)`: the store's existing full-text search (`ConversationStore.searchConversations`). It returns conversation id, title, date, role and snippet, so a hit can be followed up; `search_memory`'s conversations scope drops the id today. It reaches live and archived chats. Excluded: hidden job-run transcripts (`isBackground`; `get_job_run` reads those with their run context), the pinned conversation's own current history, and scratch conversations (never persisted).
   - `read_conversation(id, from?, count?)`: messages by position, capped at **20 messages and ~8k tokens per call**, with a "more from N" marker. It refuses job-run transcripts, the current conversation and unknown ids, each with a sentence. **Everything it returns passes the injection guard under the tool-output tag with tool-call markers stripped**, exactly as a `run_command` result does, because another chat may hold fetched web text.
   - `list_jobs` and `get_job_run` are unchanged.
   
   Invariant 6 holds: none of the four is declared anywhere else, and within the pinned conversation the list is stable, so 5a's tool-list cache misses don't arise from them. *Cost if wrong:* four declarations' tokens on every pinned turn, mostly cache reads.
6. **Reflection elsewhere reports to the pinned conversation.** A conversation that crosses 30 messages still reflects in place, where its context lives. Its summary of what changed ("Updated USER.md: …; 2 facts added") is delivered to the pinned conversation as an event card, not appended to the chat that triggered it. *Why:* memory changes are Iris-level news, and they shouldn't interrupt a working chat. *Cost if wrong:* the owner reads reflection results in a different place from where they happened. The card names the source conversation.
7. **A daily digest, deterministic, built in.** Once a day it posts a card to the pinned conversation built from the ledger:
   - runs since the previous digest, grouped by job: counts by status and the latest outcome;
   - failures and paused jobs;
   - tokens sent per job against its daily budget.
   
   No model call. Default **10:00** local (the owner's laptop is most likely open then), configurable; a quiet day (nothing ran) posts nothing. *Why:* free, can't hallucinate, and stays out of the cache question; the model reads the card when asked. *Cost if wrong:* less narrative than a written digest.
8. **The job model gains a no-model action.** Every job today carries a prompt that runs a model turn; nothing can express "post a card, no turn". Add a persisted `action` to `Job`: `.prompt` (the default, and what every existing job decodes to) or `.builtin(name)`, with `dailyDigest` the only built-in. The runner executes a built-in without a model turn, writes a ledger row as usual (status, outcome, zero tokens), and the existing catch-up, overlap and `/jobs` all apply. The digest is registered once on first launch as a cron job (`0 10 * * *`, local timezone), so it can be paused, rescheduled or deleted like any job. The model's `schedule_job` cannot create built-ins. *Why:* reuse the scheduler, ledger and `/jobs` rather than build a second timer. *Cost if wrong:* a schema change (decision 9).
9. **Persistence (invariant 1).** `Job.action` decodes with `decodeIfPresent(...) ?? .prompt`, and a test proves a job row written before 5b loads unchanged. No other persisted type changes: the summary entry is an ordinary history entry, and archiving uses existing fields.

## 1. Components

- **`Briefing`** (new, pure): `(unacknowledged failures, paused jobs, recent runs) → TurnContext.Section?`, enforcing the cap and order. `IrisEngine` asks the ledger for the three inputs on pinned turns only, and adds the section next to the fact and peer sections (5a §1).
- **`ConversationRotation`** (new): `/new` on the pinned conversation runs reflect → summarize → archive → create → move pin, with the failure path above. It reuses `/archive`'s archiving and `activityConversationId()`'s pin semantics. The summary prompt is a fixed string; its output is guarded.
- **Tools:** declared in `IrisEngine` beside `jobToolDeclarations(isPinned:)`, executed through `ConversationStore` (search, ordered message reads) with the exclusions above and the injection-guard pass.
- **Reflection routing:** the reflection trigger in `AppState.startTurn` keeps running in place. Its final summary is posted with `deliverEvent` to the pinned conversation instead of the source chat, with the source named.
- **Built-in action:** `Job.action`, the runner's built-in branch, the `DailyDigest` card builder (pure, from ledger rows), and first-launch registration.
- **Rename:** the title constant becomes "Iris", plus a one-time retitle of a pinned conversation still titled "Iris Activity".

## 2. Agent-facing text and docs (invariant 9)

Search, then fix:
- "Iris Activity" in the `schedule_job` description (it tells the model where cards go), `docs/jobs.md` (the section title and body), `EventCard.swift`, `AppState` comments, and README;
- any text implying `/new` only opens a tab;
- `search_memory`'s conversations-scope description, now that `search_conversations` exists in the pinned conversation;
- SYSTEM.md, if it describes where job results appear.

Dated specs and plans are history and are not edited.

## 3. Verification

**Unit and engine tests** (fakes, injected stores, never `ConfigManager.shared`; invariant 7):
- briefing content, order and cap; omitted (zero bytes) on a quiet ledger; present only on pinned turns;
- the four tools are declared only in the pinned conversation, and on every turn there;
- `search_conversations` returns ids, includes archived chats, excludes job-run transcripts and the current conversation;
- `read_conversation` paging, both caps, every refusal, and guard routing (a planted injection string in another chat comes back neutralised);
- `/new` rotation: reflection ran, summary entry first, old conversation archived and retitled, pin moved, and the summary-failure path;
- `/new` elsewhere unchanged;
- rename exemptions (the trigger, the tool, `/rename`'s model path);
- reflection in another chat posts its summary card to the pinned conversation and not to the source;
- digest card content; a quiet day posts nothing; the built-in runs with no model call (a fake client records zero requests); a pre-5b job row decodes to `.prompt`; `schedule_job` cannot create a built-in.

**Perf** (`perf/suites/caching.json`, a new scenario): a pinned-conversation scenario whose ledger changes between turns, so the briefing changes every turn. Pass: 5a §3's criteria still hold (first-round reads never fall, write + uncached within the allowance). This shows the briefing really costs only the tail.

**Full suite:** exit 0, the Swift Testing summary, and XCTest's "Executed N tests, with 0 failures".

## 4. Not in this deliverable

- Tool declaration policy on Anthropic, budget defaults, the 1-hour TTL: **5c**.
- Anthropic thinking replay and an append-only history: #314.
- Native surfaces (notifications, status item, URL scheme, run log view): deliverable 6.
- A model-written digest: possible later; the deterministic card comes first.
