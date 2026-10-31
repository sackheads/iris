# Iris in detail

Everything the README used to say about each feature, moved here so the README can stay short. Each heading is a link target from the README; a feature past about a screen has its own page, linked from its heading (#534).

## Architecture

At its core, Iris is a Swift-based execution chassis that bridges your local environment and cloud LLMs.

### Native GUI & Zero-Bloat Foundation

Built entirely using native Apple frameworks (`SwiftUI`, `Foundation`, `URLSession`, `Network`, `FSEventStream`).

### Concurrency

Built on modern Swift 6 Concurrency (`async/await`, `actor`), providing a high-performance, non-blocking event loop.

### Streaming Replies

Iris's answer appears as the model writes it, on Gemini (including Vertex), Anthropic, and OpenAI, with the reply growing in place at most every 50 ms. Tool calls are never acted on until their arguments have fully arrived. A failure after the first token keeps the partial text and shows the provider's error beneath it instead of retrying and duplicating what you already read; pressing Stop keeps the partial text too. Turn it off in Settings → Preferences if you prefer whole replies.

### Steer a Running Turn

Sending a message while Iris is still working does not start a second, tangled turn. The message is handed to the running turn at its next model round, after the tool results, so Iris can change course mid-task; a message with attachments waits and runs as the next turn. A turn that is stopped or fails leaves a marker in the model's history, so Iris does not quietly resume the old request when you ask something new.

### Per-Conversation Store

Conversations live in `~/.iris/conversations.sqlite`, one row per message and per model-history entry, so appending a message costs one row write off the main thread instead of re-encoding every conversation you have ever had. An unreadable entry is quarantined and reported at launch rather than taking the whole list down with it; a conversation that is unreadable in bulk is left untouched on disk and reported instead, so a fix can still recover it. If the file cannot be opened at all, Iris still starts but runs from memory, and says so at launch: nothing from that session is saved, and the old settings blob below is left for a launch whose store opens. Existing conversations are imported once from the old settings blob on first launch; the blob is kept under a legacy key for a while and then retired. Every user and agent message is also indexed for full-text search as it is written, so `/search <query>`, `search_memory` with `scope: conversations`, the sidebar's own search field, and — in Iris, your pinned main conversation — the model's own `search_conversations` and `read_conversation` tools can all find and page through what was said in any past chat — archived conversations included, background job transcripts excluded (those are `get_job_run`'s).

### LLM Engine

Natively integrates with Google's Gemini REST API, Anthropic's Claude API (directly, or Claude hosted in your own Google Cloud project through Vertex AI), and OpenAI's API. Dynamically translates complex internal agent schemas and tool executions on the fly to support advanced models like `claude-sonnet-5`, `gpt-5.6-sol`, and `gemini-3.5-flash`. Settings → Models can test every configured primary-provider model at once (Easy/Medium/Hard, plus Vision when it's set to Cloud) with a per-model pass/fail, and list the models the configured account can actually reach, each one copyable or assignable straight into a tier field.

### Subagent Providers

Settings → Models → **Subagent providers** lists providers a subagent could run on besides the primary.
- **Built-in families:** each family other than the primary (Gemini, Anthropic, OpenAI) has a **Usable by subagents** switch, which is off by default even when the family has a key. It can also list extra model ids for subagents. The main conversation's provider and its easy, medium and hard tiers never change.
- **Custom endpoints:** OpenAI-compatible servers such as DeepSeek, OpenRouter, or Ollama on this Mac.
  - Each endpoint has an id, a base URL, exact model ids, and a key.
  - The base URL must be https, except for a server on this Mac (`localhost`, `127.0.0.1` or `::1`), which is also the only kind that can go without a key.
  - The key goes in Iris's existing Keychain item and is sent only to the address it was entered for. Settings shows only `••••` and its last four characters (just "set" for a key under 8 characters), from what Iris loaded at launch, and never logs it. If the address changes, the key must be entered again.
  - A routed request follows no redirects.
  - **Check** lists the endpoint's models and marks each configured id as found or not found.
- **Prices:** in a job run, a subagent on another model is charged at that model's price ([delegation](delegation.md#subagents-on-other-providers)). Each model shows its price per million tokens and where it came from: the price list fetched daily (LiteLLM's, or OpenRouter's own for an OpenRouter endpoint), the copy bundled with Iris, or a rate you typed.
  - **Set rate…** types a rate for one model. Raising a subagent's rate is free. Lowering it is held to a tenth of the bundled price, or for a model with no bundled price, to $0.01 per million tokens. The primary's rate works the other way round, since a charge divides by it. A rate that was held says so. A subagent's rate below a tenth of its family's cheapest (for a custom endpoint, of the cheapest bundled price of any family) warns that it lowers how much of the budget the model uses. A primary rate above its bundled price (or, with none, above the dearest of any family) warns that it lowers how much every subagent uses, since their charges are counted in the primary's tokens.
  - **Check prices now** fetches the price list at once.
- **Where they're kept:** the endpoint list, the switches and your typed rates are kept with Iris's API keys in its Keychain item (#678), so a host command's `defaults write` can't add an endpoint, turn a family on, or lower a rate.
- **Using one:** the model sends a subagent to one of these with `invoke_subagent`'s `provider` and `model` arguments, which exist only while one is usable. See [delegation](delegation.md#subagents-on-other-providers) and the [spec](specs/2026-10-19-multi-model-subagents.md).

### Jobs

Scheduled and folder-watching jobs, their profiles, grants, gates, limits and cards: see [docs/jobs.md](jobs.md).

### Menu Bar Status

The menu bar item (a sparkle, or a hammer for a dev build) shows a count while background jobs run, and `!` with a count when something is waiting on you: an approval, a goal draft, checkpoint or judgement to review, a run blocked on a call, or a job paused and needing `/jobs resume`. Its menu lists each one and opens it. Failed runs and jobs you paused yourself are listed but never change the icon.

**Needs you.** The same waits put a small red dot at the end of the conversation's row in the sidebar: an approval (one a subagent or grader asked counts for the conversation it works for), a goal draft, checkpoint or judgement to review, or a run blocked on a call, shown on the conversation its card went to (the pinned Iris). Hover it to see what it is waiting on. The dot goes the moment you answer: approve or deny, approve or send back, accept or reject, or dismiss or approve the blocked card. Opening the conversation does not clear it. With no pinned Iris, a blocked run shows in the menu bar only. A question at the end of a reply does not light it.

**Unread reply.** A blue dot in the same place marks a conversation whose reply came in while you weren't looking at it: Iris in the background, the chat window hidden, or another conversation selected. A job's card landing in Iris counts too. It goes when you open the conversation, or bring Iris back to the front with it already selected. The red dot wins when both apply. It isn't saved, so quitting Iris clears every blue dot. Hidden conversations (job runs, subagents) never get one; their replies reach you through the conversation they report to (#592).

### Run Log

a window listing every background run, with its transcript one click away and Acknowledge for failures.

### Notifications

A blocked call, and a failed or interrupted run whose job is paused when its card arrives (by a limit or another admission check, not by you), post a banner — unless Iris is active with its chat window visible and showing that conversation. A live approval posts one too, unless Iris is active with its window visible, since the approval overlay is global. The title is always `Iris: a job needs you` or `Iris: approval waiting`, and the body names only the job and the tool, reduced to ASCII letters, digits and `- _ . : / + #`, never what a run said. The actions are Open; Deny, for an approval; and Dismiss, for a blocked call, which needs the Mac unlocked first. A banner never approves anything, and a blocked run's banner comes down once the run is acknowledged anywhere. Settings → General → Notifications turns them off (on by default, as "Needs attention"); only a real app bundle posts them, so `swift run` and `scripts/run-dev.sh` never do.

### Built-in OAuth

Includes a dependency-free TCP loopback listener for Google Workspace OAuth, enabling safe, native integrations with **Google Calendar, Docs, Drive, Sheets, Gmail, and Tasks**.

### Subagent Sandboxing

Transparently routes terminal execution through `apple/container` lightweight Linux VMs. The VM itself is thrown away, but the conversation's workspace is mounted into it read-write: what a command writes there lands on your Mac and stays.

So a sandboxed command refuses to run when that workspace is your home folder or a folder above it, or is or holds a place your Mac runs programs or settings from (`~/Library/LaunchAgents`, `~/.config`, `~/bin`, `~/.local/bin`), a credential store (`~/.ssh`, `~/.aws`, the Keychains folder and the like), or Iris's own settings. Code left in any of those could run on your Mac later, even in a command you approve yourself. Nothing runs and nothing falls back to the host; the reply says why. If you do want it for one conversation, right-click it in the sidebar and choose **Let the Sandbox Write This Folder…**. After a confirmation naming what becomes writable, that conversation (and its subagents and grader) may mount exactly that folder, unless it holds git repositories of yours ([details](sandbox_repositories.md)), the row shows **home writable by the sandbox**, and Vibecop then lets only read-only commands run in its sandbox without asking. The same menu stops it. Only you can turn it on: no tool, job or message can, and a dev home seeded from the installed app does not carry it over.

### Repositories in the Sandbox

When a sandboxed workspace is a git repository, the VM can't choose what git on your Mac runs: git in the VM works on a git dir of its own, your `.git` goes in only read-only, and the sandbox's commits come back as a bundle, moving your branch only on a clean fast-forward and saying so in the chat (#623, #658). [Details](sandbox_repositories.md)

### Workspace Binding

Link chat sessions to local filesystem directories. Iris will automatically load the project's `AGENTS.md` instructions and execute terminal commands from within that project context.

### Autonomous Goal Loops

Type `/goal` to kick off a long-running, self-prompting autonomous loop. Iris will continue executing tools and reflecting until the goal is fully accomplished. Goal state persists across app restarts — if Iris quits or crashes mid-goal, it picks up where it left off on next launch. A goal that was waiting on you does not: one paused at a checkpoint or awaiting your verdict stays paused, so a restart never resumes work you had stopped to look at, and a goal that hit its iteration cap stays stopped.

### Token Tracking & Diagnostics

Token counts, prompt caching, the Diagnostics charts and Claude thinking replay: see [docs/token-usage.md](token-usage.md).

### Auxiliary Models Framework

Native support for local smaller models for background tasks like Vibecop. Supports embedded `llama.cpp` (GGUF weights), local `ollama` daemons, and blazing fast Apple Silicon native inference via `MLX`.

### Prompt Injection Defense

Includes a multi-tiered security pipeline (Structural Isolation + Behavioral Canary Probes) to actively neutralize indirect prompt injections hidden within untrusted external data.

### Outbound Send Gate

Once a conversation has read untrusted content, sending mail, creating calendar events or tasks, searching the web (the query is a way out too, #825), and any MCP tool not marked read-only ask you first, and a job run refuses them unless the job exempts the tool (#812). The cost in prompts: an attended conversation asks on the first send of each such tool; Vibecop and the command allowlist (`PermissionManager`) can't answer, because the model wrote the recipient and body from the tainted content; **Allow in This Conversation** ends the prompts for that tool there; and an unattended run never asks. The per-job exemptions and the per-conversation allow are your exemption list, and only you set them. [Details](jobs.md#outbound-sends-after-untrusted-content)

### Rich Native UI

Beautiful macOS `NavigationSplitView` with multi-conversation support — a conversation you archive collapses into its own Archived section, out of the main list but one right-click away — `.regularMaterial` frosted glass input bars, and native markdown chat rendering powered by `swift-markdown-ui`. The sidebar's search field finds any past conversation by what was said in it, grouping ranked hits per conversation and jumping straight to the matching message when you pick one; hidden conversations (job runs, subagent logs) stay out of the results, the same as they stay out of the list.

### Model Status LEDs

A compact row of retro LED indicators sits between the chat area and input bar, showing real-time status of every inference model: primary tier (color-coded by difficulty), Vibecop Guardian, and all three Prompt Injection Guard tiers. On a wide window the row steps up to a larger size. Green = ready, orange = warming/configured, gray = off, with a pulsing glow during active inference. A deeper orange on P2/P3 means that guard tier's model is named but not downloaded, so the tier is being skipped; P2 with no model set, the default since #781, is gray; **red means the model is installed but failing to load or run**, which is different and worse — that tier is blocking guarded output rather than checking it, and the tooltip carries the error so you can tell a half-unzipped directory from a truncated download. A tier in that state also says so once in the conversation, because a red light you are not looking at is not a warning. Click a light, or its label, for its details: what it is doing in words, the model and engine behind it, and for a red tier the whole error. A light that isn't green also offers one step, which opens Settings on the tab where the fix is (Models for PRI, Vibecop for VC, Security for P1 to P3), and starts nothing itself. PRI's details name the model this conversation runs on, and where its tier came from (`/model`, its agent profile, or the default), then the configured defaults. Settings → General → "Show model activity LEDs" hides the row if you would rather have the space; the guard notice is not affected by it.

While a local model loads, a line above the LEDs says so, with the seconds counting: `Loading guard (tier 3) model: gemma4:12b [12s]`.  One line per load, oldest first, three at most and then "+N more".  It shows with the LEDs hidden too, and goes away when the load ends; a load that fails just disappears, and the red light reports it.  Iris starts loading the guard's and Vibecop's Ollama or llama.cpp model at launch (#792), so the line usually shows then rather than on your first prompt.  For Ollama the load ends when Ollama answers Iris's warm-up request, which it does only once the model is in memory.  Ollama unloads a model after five idle minutes, so the next guard or Vibecop call re-sends that warm-up and the line shows again.  If Ollama doesn't say which models it has loaded, nothing shows.  Cloud engines load nothing, so they never show a line.

### Loops

`/loop 10m check my open PRs` re-runs a prompt in the same conversation on a cadence, with ticks you can watch, interrupt and talk back to.  Leave the interval out (`/loop check my open PRs`) and it's self-paced: Iris picks each next wait, from a minute to an hour, and 20 minutes when it doesn't say.  A chip above the composer shows the cadence, the ticks left and when the next is due, with Pause, Resume and Stop.  Ticks run attended (an approval waits for you, as under `/goal`), each one resends the conversation so far, and a loop stops at the Loop tick limit (Settings → Advanced → Agent Limits, default 50).  It comes back paused after a relaunch.  For work that should run with nobody watching, use a [job](jobs.md).  Details: [slash commands](slash_commands.md), [spec](specs/2026-10-19-loop.md).

### Goal Workspaces

A goal with a contract gets its own directory instead of running wherever Iris happens to be. Iris proposes one when you start a goal — the project's own path if the goal is about existing code, or a fresh directory under `~/.iris/workspaces/` if it is building something new — and shows it for you to edit before you approve. Artifacts land somewhere you chose, and the independent grader checks the goal's own files rather than whatever was in the current directory. Settings → Advanced → **Goal Workspaces** lists every workspace under that directory, flags the ones no conversation still points at as orphans, and deletes any of them to the Trash.

### Deterministic Done-Gates

With a goal contract active, Iris cannot simply declare itself finished. `goal_complete` is gated on an independent grader's verdict: any criterion the grader finds unmet sends Iris back to work with the evidence attached. If a criterion genuinely does not apply, Iris must say so out loud with a reason, which is shown to you beside the grader's verdict rather than in place of it. The grader runs each executable check you approved when you locked the contract, in the workspace you approved it for, and reads files and lists directories inside that workspace, without asking you again; anything else it runs, including a check the agent added or changed through `amend_goal_contract`, goes through the usual approval (see [Vibecop Guardian](vibecop.md)). After a configurable number of failed attempts the goal finishes anyway — and is labelled plainly as having completed without passing, so an unfinished goal can never quietly look like a finished one. Criteria marked "human-judged" are never graded by a machine: when they are all that stands between a goal and completion, the run pauses and asks you, and your verdict is labelled as yours rather than presented as verified. A checkpoint along the way that stops on an undecided human-judged criterion asks you for the verdict right there, on the checkpoint panel; a verdict you give at a checkpoint is never asked for again. A criterion you sent back is put to you again once the work has actually changed.

### Graded Delegation

Delegating work to a subagent with a definition of done, graded by an independent evaluator: see [docs/delegation.md](delegation.md).

### Checkpoint Delegation

When a goal has a checkpoint ladder, Iris can hand the current milestone to a subagent that works it in its own context. The milestone's criteria come straight from the locked contract — the agent cannot restate what it is about to be measured against — and when the subagent finishes, the checkpoint is reached and graded automatically: a clean grade advances without pausing you, exactly as it would for work done directly, and anything contested still stops the ladder for your review. The grade spans every milestone so far, so work that quietly breaks an earlier milestone is still caught.

### Checkpoint Auto-Advance

A goal's criteria can be grouped into an ordered checkpoint ladder, stopping the run for your review at each milestone rather than only at the very end. A checkpoint the independent grader passes cleanly now advances on its own instead of pausing you — a clean grade only means the grader found nothing wrong, not that a human looked, so a grader's mistake advances just as unseen as a correct one. Anything contested still stops the ladder: a criterion the grader found unmet, one it could not verify, a grader that errored or timed out, or a "human-judged" criterion you have not yet decided, which stops the run and asks you for the verdict on the checkpoint panel (Approve stays disabled until every human-judged criterion in that milestone is accepted; Send back consumes a rejection so the agent reworks it), and a verdict you have already given is never asked for twice. A checkpoint whose grade is stopped — you pressed Stop, or its run closed — is neither advanced nor paused for review: nothing was graded, so it is graded afresh when the agent reaches it again. Every checkpoint's outcome — auto-advanced, approved, or sent back — is recorded on the conversation rather than on the goal contract, so it survives both the goal ending and a relaunch (it is a column of its own in the conversation database), and each auto-advance also writes a line into the transcript naming the milestone and the evidence it passed on, so the ladder stays inspectable even when nobody stopped to look. Settings → General → Goals turns it off from the next checkpoint on, restoring a pause at every checkpoint after that, alongside how many times the done-gate sends Iris back before a goal finishes without passing.

### Session Strip

A compact, per-session activity strip below the composer — one line per running (or just-finished) session with its role, current activity (thinking, responding, or the tool it's running), elapsed time, and token usage. The toolbar "cpu" badge toggles it between a single main-session line and the full list; clicking a subagent or evaluator row opens a read-only transcript of that session's conversation, and a running subagent's row has a Stop button that ends just that subagent: its result comes back `cancelled` to the conversation that delegated it, which is woken to re-plan without it. Finished sessions linger briefly before aging out. Subagents dynamically self-assign the Easy, Medium, or Hard model tiers based on task complexity.

### Markdown Export & Utilities

Right-click conversations to archive or unarchive them, copy them to your clipboard as clean, formatted Markdown, or select specific chat turns to copy just those. Archiving is refused while a turn is still running or a goal is active on that conversation, and refused outright on Iris, your pinned main conversation — `/new` there archives it for you (see Session Control under [Slash commands](#slash-commands)). Sending anything to an archived conversation — a message, a subagent post-back — brings it back automatically, with two deliberate exceptions: a message from another session is refused instead of un-archiving it, and a job's event card lands silently, because a card starts no turn and an archived conversation is meant to stay idle. A human reopening a conversation is a choice about one thing they picked; a peer doing the same would be expanding its own reach on its own initiative, so it doesn't get to. A session left untouched archives itself after 14 days by default ([details](sessions.md)); a plain chat never does. Automatically renames conversations via the `/rename` command — except Iris, which keeps its name.

### Agent Profiles

Start a conversation as a reviewer, researcher or writer: a profile is a Markdown file of your own that adds to the system prompt and gives the conversation its role, chosen from the profile button beside New Conversation, or applied to a conversation later from its right-click menu. A profile only adds and narrows; it never approves anything. [Details](agent_profiles.md)

### Sessions

Conversations as sessions that can see and message each other, with roles, cards and limits: see [docs/sessions.md](sessions.md).

## Memory and skills

Markdown memory and skills, reflection, the fact store and always-on rules: see [docs/memory.md](memory.md).

## Plugins

Iris supports installable plugins via the **Iris Plugin Format (IPF)**, an
open, versioned bundle format that lives alongside OKF. A plugin is one
directory that bundles an MCP server (`mcp.json`), Agent Skills
(`skills/`), and always-on rules (`rules/`) behind a single `plugin.md`
manifest.

*   **Settings → Plugins tab:** Lists installed plugins with a status LED
    (green = running, orange = needs configuration or sign-in, red =
    failed, gray = disabled), plus a detail pane for configuration,
    servers/tools, and skills/rules.
*   **Three install flows:** *From Folder* (a local or symlinked plugin
    directory, with a dev-mode Reload button), *From MCP Snippet* (paste a
    standard `mcpServers` JSON block and Iris generates the plugin), and
    *Import from Another Harness* (pull server configs from Claude
    Desktop, Claude Code, Cursor, Windsurf, Gemini CLI, or VS Code
    Copilot).
*   **Secrets in Keychain:** Any secret a plugin declares is collected by
    the install wizard and stored in the macOS Keychain under its own
    service (`iris.plugin.<id>`) — never on disk, never in the plugin
    directory. Uninstalling a plugin removes its Keychain entry too.
*   The hand-edited `mcp_servers.json` file keeps working unchanged
    alongside plugins; a **Convert to plugin** action wraps any of its
    entries into a plugin on demand.

See [docs/ipf/spec.md](ipf/spec.md) for the normative manifest format
and [docs/ipf/authoring.md](ipf/authoring.md) for a plugin-author
guide with worked examples.

## Model Context Protocol (MCP)

Natively acts as an MCP client, dynamically loading external tool servers (like Postgres or SQLite) straight into the agent's brain.

An MCP tool's result counts as untrusted content, and a tool its server didn't mark `readOnlyHint: true` counts as outbound: once a conversation has read untrusted content, each such tool asks before its first call there, and **Allow in This Conversation** stops it asking ([Outbound Send Gate](#outbound-send-gate)). Iris trusts the server's own marking; a server you don't trust shouldn't be installed.

Iris natively supports the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/). 

To configure MCP servers, create a JSON file at `~/.iris/mcp_servers.json` with your server configurations:

```json
{
  "postgres": {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost/mydatabase"]
  },
  "sqlite": {
    "command": "uvx",
    "args": ["mcp-server-sqlite", "--db-path", "~/mydatabase.db"]
  }
}
```

Once configured, Iris will automatically boot these servers in the background and their tools will be available for Iris to use.

## Core native tools

The built-in tools the model is given (`run_command`, the file tools, `schedule_job` and the rest): see [docs/tools.md](tools.md).

## Global hotkey

Iris runs in the background and can be summoned instantly over any other app by pressing **`Cmd + Shift + Space`** (configurable in Settings) — the installed app's default. A build from source uses `Cmd + Shift + Option + Space` instead (see [Building from source](building.md)).

## Slash commands

Commands typed into the composer, most of which run without a model turn: see [docs/slash_commands.md](slash_commands.md).

## Provider errors and retries

When a model call fails, Iris shows a compact red system pill with a one-line headline (provider, HTTP status, and the provider's message). The provider's raw response is available behind a chevron, capped at 2 KB; the full body goes to the console log. Rate limits and overloads (HTTP 429, 503, 529), request timeouts, and lost connections are retried automatically before the error is shown, with a 2 s / 4 s / 8 s backoff (±25% jitter) or the provider's `Retry-After` when it sends one, and each retry is announced as a `[retry]` system line. Each provider request is allowed 180 s before it counts as timed out. With streaming on, a failure before the first token retries exactly as above; a failure after it is shown as `Response interrupted: …` under the partial reply and is not retried. A reply the provider cut off — at its output limit (Anthropic `max_tokens`, Gemini `MAX_TOKENS`, OpenAI `length`) or at the context window (Anthropic `model_context_window_exceeded`) — keeps its text and gets the same red pill saying it is cut off, on every provider; a cut round that still made tool calls gets an `[output limit]` line instead and the turn carries on. A tool call cut off partway is never run. On Anthropic, `max_tokens` is sized per model (32000 for current models, 16000 for an id Iris does not know, 4096 for retired 3.x ids), at most 8192 when streaming is off, and never more than a budgeted run's remaining weighted tokens can pay for (at least 1024).

## Google Workspace

In the settings window, you can enter your Google OAuth Client ID and Secret, and click **Connect to Google**. Iris will spin up a local listener, redirect you to Google for consent, and seamlessly exchange your authorization code for valid access and refresh tokens.

The **Integrations tab** now includes a collapsible **Setup Guide** that walks you through both the `gcloud` CLI path (recommended) and the Google Cloud Console web path. It auto-detects your gcloud installation, authenticated account, and GCP project, and provides a one-click checklist to enable the six required APIs (Calendar, Drive, Docs, Sheets, Gmail, Tasks). See [docs/google_workspace_oauth_setup.md](google_workspace_oauth_setup.md) for the full walkthrough.

Once connected, Iris has native API access to the following Workspace tools directly from Swift (they are offered to the model only while a Google account is connected, so an unconnected install does not spend prompt tokens on them):
*   **Google Calendar**: `google_calendar_list_events`, `google_calendar_create_event`
*   **Google Docs**: `google_docs_get`
*   **Google Drive**: `google_drive_search`
*   **Google Sheets**: `google_sheets_get`
*   **Google Tasks**: `google_tasks_list_tasklists`, `google_tasks_list_tasks`, `google_tasks_create_task`
*   **Gmail**: `gmail_list_unread`, `gmail_send_email`

The three that send or create (`gmail_send_email`, `google_calendar_create_event`, `google_tasks_create_task`), like `search_web`, ask first once the conversation has read untrusted content ([Outbound Send Gate](#outbound-send-gate)).

## File attachments and auxiliary vision

Iris supports attaching files directly to your prompt using the **📎 attachment button** or via **drag & drop**:
*   **Supported Formats**: Images (`.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`), PDFs (`.pdf`), rich documents (`.docx`, `.rtf`), and text/code files (`.txt`, `.md`, `.json`, `.swift`, `.py`, etc.).
*   **Document Text Parsing**: Text, PDF, and rich text documents are automatically parsed into plain text blocks and appended to the prompt context (up to 100,000 characters per file).
*   **Vision Routing & Auxiliary Configuration**: When attached to vision-capable models (e.g., Gemini 2.0 Flash, Claude 3.5 Sonnet, GPT-4o), images are passed directly in the inline payload. If the active model lacks vision capabilities, Iris automatically routes images to a configured Auxiliary Vision Model (such as local `ollama` with `llava`) to generate detailed image descriptions.
*   **File Size Limits**: Built-in guardrails restrict individual image files to **20 MB** and document/PDF/text files to **50 MB**. Oversized attachments trigger a warning and are safely excluded from memory.

## Vibecop Guardian

The optional guardian model that pre-screens commands and file operations, "Always allow" rules, and how a file operation's path is judged: see [docs/vibecop.md](vibecop.md).

## Inspiration

A key bit of Iris's agentic workflow is heavily inspired by the philosophy of [obra/superpowers](https://github.com/obra/superpowers). In particular, we natively enforce the following principles in the agent's system prompt:
*   **Brainstorming First:** The agent must explore context, ask clarifying questions, and propose trade-offs before writing a single line of code.
*   **Design Docs (Specs):** Designs must be presented and approved, then written to `specs/` directories.
*   **Implementation Plans:** Complex designs are broken down into step-by-step plans.
*   **Test-Driven Development (TDD):** The "Iron Law" of testing first. No production code is written without observing a failing test first (RED -> GREEN -> REFACTOR).
*   **Execution Loop:** Implementing code iteratively and reviewing it until the feature matches the specs.
