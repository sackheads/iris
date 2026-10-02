# Agency deliverable 5b: The main conversation

Status: **proposed** (2026-10-01). Deliverable 5b of #187. 5a (`2026-09-30-agency-cacheable-prompts.md`, #312, #320) made prompts cacheable and added the per-turn `<turn_context>` block that this deliverable's briefing rides. Three settings 5a's measurements raised apply to every conversation, not just this one: tool declaration policy on Anthropic (invariant 6), the budget defaults, and the cache TTL. They are **not** decided here; they get their own short spec, 5c.

The pinned conversation exists already: deliverable 2 created it as **Iris Activity**, where job event cards land (`AppState.activityConversationId()`, `docs/jobs.md` "Event cards and the Iris Activity conversation"). 5b makes it the conversation the owner talks to every day. It knows what background work has been doing, it can look back through other chats, and it stays cheap to keep forever.

## 0. Decided

Each decision names its default and why; the cost of being wrong is what a reviewer should weigh.

1. **One pinned conversation, named "Iris".** `activityConversationId()` stays the single way to find or create it, and the pin is still `isPinned`. The default title becomes **Iris**. On launch, an existing pinned conversation still titled exactly "Iris Activity" is retitled; one the owner renamed keeps its name. *Why:* it is now the main conversation, not a log. *Cost if wrong:* a title.
2. **Exemptions.** The pinned conversation is never auto-renamed, on any of the four paths: the 3-message rename trigger, the `rename_conversation` tool, `/rename`'s model path, and `appendMessage`'s auto-title from the first user message (which would otherwise retitle a freshly rotated Iris). `/clear` stays refused, and **`/archive` is refused** too: archiving the pinned conversation is what `/new` does, in the order that keeps the pin valid. It **does** auto-reflect, at the same 30-message threshold as any conversation, and also at `/new` (decision 4). *Why:* the owner expects meaningful learning to happen there. *Cost if wrong:* one reflection turn per 30 messages.
3. **The briefing rides 5a's turn-context block.** On pinned-conversation turns only, the turn context gains a `# Recent Activity` section, built fresh from the job ledger each turn:
   - every unacknowledged failure, and every paused job;
   - then the most recent notable runs, failures first, up to **five lines in total beyond the pinned items**.
   
   One line each, **harness-owned fields only**: the job name (structurally sanitised and length-capped), the status, a fixed-vocabulary reason (e.g. `budget`, `timeout`, `blocked: <tool>`, `gate error`), and the run id. **Never a run's free-text outcome.** Since 5a, the turn-context block neutralises every `<`, so nothing inside it can be wrapped as untrusted, and text there arrives with the harness's authority. A job's outcome can carry fetched or injected text, so the model calls `get_job_run` for the words, through the guarded tool path. The section is omitted when there is nothing to say, so a quiet day adds zero bytes. It is built once per turn, before the turn's request is assembled, and it is best-effort: a ledger read that fails omits the section rather than failing the turn. SYSTEM.md's description of the turn-context block names the briefing. *Why:* 5a measured that per-turn content in this block costs about one turn's tail, not a re-write, and the agency epic's "Decided in review" fixed the cap ("five recent events, plus every unacknowledged failure and paused job"). *Cost if wrong:* a longer per-turn block when many things fail at once, which is the moment it should be long.
4. **`/new` in the pinned conversation rotates it.** In order:
   1. refuse, with `/archive`'s sentences, if a turn is in flight or a goal is active;
   2. run one reflection pass in place, so durable learning reaches memory before the history leaves context;
   3. create the fresh pinned conversation and **move the pin (the `activity_conversation_id` meta key) now**. Job cards are routed through `activityConversationId()` at each delivery, so every card from here on lands in the new conversation, never in the one about to be archived;
   4. write a summary of the old conversation, at most ~400 tokens (decisions made, open threads, follow-ups the owner asked for). One easy-tier call; the result passes the injection guard, and it becomes the new conversation's first entry;
   5. archive the old conversation (`/archive`'s mechanism, retitled "Iris — ‹first date›–‹last date›"). It stays searchable and readable. Archiving comes last because any turn start un-archives a conversation (`runThinkingTask`).
   
   Invariant, tested on every path including summary failure: the meta key never points at an archived or missing conversation. If the summary call fails, the rotation still completes, and the new conversation's first entry says no summary was produced and names the archived conversation.

   Nothing rotates automatically. When the pinned conversation's history passes ~150k tokens, Iris posts a one-line suggestion to run `/new`, once per crossing. The owner decides when context resets. Elsewhere `/new` keeps today's behaviour (a new tab). *Why:* the owner chose "archive, but summarize". Archiving rather than trimming keeps the transcript reachable through `read_conversation`. *Cost if wrong:* one model call per rotation.
5. **Tools, pinned conversation only, declared on every turn there.**
   - `search_conversations(query, limit?)`: the store's existing full-text search (`ConversationStore.searchConversations`). It returns conversation id, title, date, role and snippet, so a hit can be followed up; `search_memory`'s conversations scope drops the id today. It reaches live and archived chats. Excluded: hidden job-run transcripts (`isBackground`; `get_job_run` reads those with their run context), the pinned conversation's own current history, and subagent/evaluator conversations (never persisted, so never reachable). The store's search has no such filter today, so it gains one, and `ConversationHit` gains the conversation's `updatedAt` as the date.
   - `read_conversation(id, from?, count?)`: the conversation's user and agent messages (the same roles the search index holds, so a hit's position pages correctly; tool-call pills and system lines are excluded) by position, capped at **20 messages and ~8k tokens per call**, with a "more from N" marker. It refuses job-run transcripts, the current conversation and unknown ids, each with a sentence. **Everything it returns passes the injection guard under the tool-output tag with tool-call markers stripped**, exactly as a `run_command` result does, because another chat may hold fetched web text.
   - `list_jobs` and `get_job_run` are unchanged.
   - **Job creation needs approval in the pinned conversation.** That conversation reads other chats and has the job tools, so an injection that survived the guard could otherwise create a standing job. There, `schedule_job` and `register_directory_watcher` go through the normal approval prompt, as `run_command` does, every time. The owner chose a human gate over a taint rule.
   
   Invariant 6 holds: none of the four is declared anywhere else, and within the pinned conversation the list is stable, so 5a's tool-list cache misses don't arise from them. *Cost if wrong:* four declarations' tokens on every pinned turn, mostly cache reads.
6. **Reflection elsewhere reports to the pinned conversation.** A conversation that crosses 30 messages still reflects in place, where its context lives. Its summary of what changed ("Updated USER.md: …; 2 facts added") is delivered to the pinned conversation as an event card, not appended to the chat that triggered it. Capture: `processInput` returns nothing, so the trigger snapshots the source conversation's message count before the reflection turn and takes the agent messages after it. A reflection the model ends with "No memory consolidation needed" posts no card. `EventCard` is tied to job runs today (required `runId`/`jobId`, "job" headlines), so it gains a `reflection` kind with its own fields and rendering; job cards are unchanged. The card's text is the model's own summary of its memory edits, so it is delivered through `deliverEvent`'s guard like any card. *Why:* memory changes are Iris-level news, and they shouldn't interrupt a working chat. *Cost if wrong:* the owner reads reflection results in a different place from where they happened. The card names the source conversation.
7. **A daily digest, deterministic, built in.** Once a day it posts a card to the pinned conversation built from the ledger:
   - runs since the previous digest, grouped by job: counts by status and the latest outcome;
   - failures and paused jobs;
   - tokens sent per job against its daily budget.
   
   No model call. Default **10:00** local (the owner's laptop is most likely open then), configurable; a quiet day (nothing ran) posts nothing. *Why:* free, can't hallucinate, and stays out of the cache question; the model reads the card when asked. *Cost if wrong:* less narrative than a written digest.
8. **The job model gains a no-model action.** Every job today carries a prompt that runs a model turn; nothing can express "post a card, no turn". Add a persisted `action` to `Job`: `.prompt` (the default, and what every existing job decodes to) or `.builtin(name)`, with `dailyDigest` the only built-in. The runner executes a built-in without a model turn, writes a ledger row as usual (status, outcome, zero tokens), and the existing catch-up, overlap and `/jobs` all apply. The digest is registered once as a cron job (`0 10 * * *`, local timezone), so it can be paused, rescheduled or deleted like any job. A meta-key marker records that registration happened, so a digest the owner deleted is not recreated on the next launch. Built-in runs **skip the token-budget admission**: a zero-token run would otherwise be refused by a spent daily budget on exactly the day the digest matters. Their policy is pinned to `catchUp: .coalesce`, and they write a run row with no transcript (`get_job_run` already tolerates a missing transcript id; a test pins it). The model's `schedule_job` cannot create built-ins. Built-ins are a registry keyed by name, so the next model-free job (there are many: housekeeping, a status card, a sweep) is one registered entry, not a schema change. User-defined model-free jobs, such as a sandboxed script whose output is posted as a card, are a natural extension and are tracked separately. *Why:* reuse the scheduler, ledger and `/jobs` rather than build a second timer. *Cost if wrong:* a schema change (decision 9).
9. **Persistence (invariant 1).** Jobs are stored as SQL columns, not through `Job`'s `Codable`, so `action` needs a store migration (a new column, nullable, meaning `.prompt` when null), a write in `JobLedger.upsert` and a read in `JobLedger.job(from:)`, as well as `decodeIfPresent(...) ?? .prompt` in `init(from:)`. A test proves a job row written before 5b loads as `.prompt`. No other persisted type changes: the summary entry is an ordinary history entry, and archiving uses existing fields.

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

**Perf** (`perf/suites/caching.json`, a new scenario): a pinned-conversation scenario whose ledger changes between turns, so the briefing changes every turn, and which delivers an event card mid-turn (the case where 5a's event-line cost is paid most). Pass: 5a §3's criteria still hold (first-round reads never fall, write + uncached within the allowance). This shows the briefing really costs only the tail.

**Full suite:** exit 0, the Swift Testing summary, and XCTest's "Executed N tests, with 0 failures".

## 4. Not in this deliverable

- Tool declaration policy on Anthropic, budget defaults, the 1-hour TTL: **5c**.
- Anthropic thinking replay and an append-only history: #314.
- Native surfaces (notifications, status item, URL scheme, run log view): deliverable 6.
- A model-written digest: possible later; the deterministic card comes first.
