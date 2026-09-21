# 🌈 Iris: Native macOS Agent Harness

Iris is a lightweight, compiled, native macOS agent harness designed to run autonomous AI workflows locally without heavy runtime dependencies (like Node/npm) that might be blocked by enterprise endpoint management.

It features **native Model Context Protocol (MCP) support** for limitless tool expansion and **built-in zero-dependency Google Workspace integrations** (Calendar, Docs, Drive, Sheets, Gmail, and Tasks).

![Iris Screenshot](assets/screenshot_1.jpg)
<br/>
![Setup Wizard](assets/wizard.jpg)

## 🚀 Architecture

At its core, Iris is a Swift-based execution chassis that bridges your local environment and cloud LLMs.
*   **Native GUI & Zero-Bloat Foundation:** Built entirely using native Apple frameworks (`SwiftUI`, `Foundation`, `URLSession`, `Network`, `FSEventStream`).
*   **Concurrency:** Built on modern Swift 6 Concurrency (`async/await`, `actor`), providing a high-performance, non-blocking event loop.
*   **Streaming Replies:** Iris's answer appears as the model writes it, on Gemini (including Vertex), Anthropic, and OpenAI, with the reply growing in place at most every 50 ms. Tool calls are never acted on until their arguments have fully arrived. A failure after the first token keeps the partial text and shows the provider's error beneath it instead of retrying and duplicating what you already read; pressing Stop keeps the partial text too. Turn it off in Settings → Preferences if you prefer whole replies.
*   **Steer a Running Turn:** Sending a message while Iris is still working does not start a second, tangled turn. The message is handed to the running turn at its next model round, after the tool results, so Iris can change course mid-task; a message with attachments waits and runs as the next turn. A turn that is stopped or fails leaves a marker in the model's history, so Iris does not quietly resume the old request when you ask something new.
*   **Per-Conversation Store:** Conversations live in `~/.iris/conversations.sqlite`, one row per message and per model-history entry, so appending a message costs one row write off the main thread instead of re-encoding every conversation you have ever had. An unreadable entry is quarantined and reported at launch rather than taking the whole list down with it; a conversation that is unreadable in bulk is left untouched on disk and reported instead, so a fix can still recover it. Existing conversations are imported once from the old settings blob on first launch; the blob is kept under a legacy key for a while and then retired. Every user and agent message is also indexed for full-text search as it is written, so `/search <query>`, `search_memory` with `scope: conversations`, and the sidebar's own search field can all find what was said in any past chat — archived conversations included.
*   **LLM Engine:** Natively integrates with Google's Gemini REST API, Anthropic's Claude API, and OpenAI's API. Dynamically translates complex internal agent schemas and tool executions on the fly to support advanced models like `claude-sonnet-5`, `gpt-5.6-sol`, and `gemini-3.5-flash`. Settings → Models can test every configured primary-provider model at once (Easy/Medium/Hard, plus Vision when it's set to Cloud) with a per-model pass/fail, and list the models the configured account can actually reach, each one copyable or assignable straight into a tier field.
*   **Jobs:** `schedule_job` creates a job on a cron schedule (five fields, with a per-job IANA time zone) or a plain interval; `register_directory_watcher` creates a job that watches a directory via `FSEventStream` and fires when files under it change. Jobs are stored in the conversation database and survive restarts. A background scheduler polls for due jobs every 10 seconds and again right after the Mac wakes; a job that came due while asleep fires once and is rescheduled from then, rather than replaying every missed tick. A fire runs in a hidden conversation of its own and reports one event card into the pinned "Iris Activity" conversation instead of interrupting whatever you have open, with every run recorded in a ledger; `/jobs` lists what is scheduled, acknowledges a failed run, pauses, resumes or fires a job now, or deletes one, without spending a model turn. A run is bounded while it happens — a per-run token budget and a wall-clock timeout end the turn rather than letting it spend unattended, and the Mac is kept awake for the run's own duration and no longer — and a failed run is retried after 1, 5 and 25 minutes before the job pauses itself with "failed 3 times; paused" (a watch fire is not retried — the next save re-runs it with real paths — and neither is a hand-started fire of a watch job, which never had paths at all). A background run is never offered the two job-creating tools and is refused them if it calls one anyway — nothing schedules more work for itself unattended — and a watch fire for a job already running is dropped rather than started alongside it. See [docs/jobs.md](docs/jobs.md).
*   **Built-in OAuth:** Includes a dependency-free TCP loopback listener for Google Workspace OAuth, enabling safe, native integrations with **Google Calendar, Docs, Drive, Sheets, Gmail, and Tasks**.
*   **Model Context Protocol (MCP):** Natively acts as an MCP client, dynamically loading external tool servers (like Postgres or SQLite) straight into the agent's brain.
*   **Subagent Sandboxing:** Transparently routes terminal execution through `apple/container` lightweight Linux VMs, allowing Iris to safely execute potentially dangerous autonomous behavior.
*   **Workspace Binding:** Link chat sessions to local filesystem directories. Iris will automatically load the project's `AGENTS.md` instructions and execute terminal commands from within that project context.
*   **Autonomous Goal Loops:** Type `/goal` to kick off a long-running, self-prompting autonomous loop. Iris will continue executing tools and reflecting until the goal is fully accomplished. Goal state persists across app restarts — if Iris quits or crashes mid-goal, it picks up where it left off on next launch. A goal that was waiting on you does not: one paused at a checkpoint or awaiting your verdict stays paused, so a restart never resumes work you had stopped to look at, and a goal that hit its iteration cap stays stopped.
*   **Token Tracking & Diagnostics:** Real-time visibility into prompt/candidate tokens, plus a dedicated Diagnostics UI that charts LLM latency metrics across different model tiers and Vibecop requests.
*   **Auxiliary Models Framework:** Native support for local smaller models for background tasks like Vibecop. Supports embedded `llama.cpp` (GGUF weights), local `ollama` daemons, and blazing fast Apple Silicon native inference via `MLX`.
*   **Vibecop Guardian Mode:** An ultra-paranoid AI guardian that evaluates terminal commands and file operations for safety, auto-approving routine actions and escalating dangerous ones to the user. Includes "Always allow" and "Always allow in project" persistence.
*   **Prompt Injection Defense:** Includes a multi-tiered security pipeline (Structural Isolation + Behavioral Canary Probes) to actively neutralize indirect prompt injections hidden within untrusted external data.
*   **Rich Native UI:** Beautiful macOS `NavigationSplitView` with multi-conversation support — a conversation you archive collapses into its own Archived section, out of the main list but one right-click away — `.regularMaterial` frosted glass input bars, and native markdown chat rendering powered by `swift-markdown-ui`. The sidebar's search field finds any past conversation by what was said in it, grouping ranked hits per conversation and jumping straight to the matching message when you pick one; hidden conversations (job runs, subagent logs) stay out of the results, the same as they stay out of the list.
*   **Model Status LEDs:** A compact row of retro LED indicators sits between the chat area and input bar, showing real-time status of every inference model: primary tier (color-coded by difficulty), Vibecop Guardian, and all three Prompt Injection Guard tiers. Green = ready, orange = warming/configured, gray = off, with a pulsing glow during active inference.
*   **Goal Workspaces:** A goal with a contract gets its own directory instead of running wherever Iris happens to be. Iris proposes one when you start a goal — the project's own path if the goal is about existing code, or a fresh directory under `~/.iris/workspaces/` if it is building something new — and shows it for you to edit before you approve. Artifacts land somewhere you chose, and the independent grader checks the goal's own files rather than whatever was in the current directory. Settings → Advanced → **Goal Workspaces** lists every workspace under that directory, flags the ones no conversation still points at as orphans, and deletes any of them to the Trash.
*   **Deterministic Done-Gates:** With a goal contract active, Iris cannot simply declare itself finished. `goal_complete` is gated on an independent grader's verdict: any criterion the grader finds unmet sends Iris back to work with the evidence attached. If a criterion genuinely does not apply, Iris must say so out loud with a reason, which is shown to you beside the grader's verdict rather than in place of it. After a configurable number of failed attempts the goal finishes anyway — and is labelled plainly as having completed without passing, so an unfinished goal can never quietly look like a finished one. Criteria marked "human-judged" are never graded by a machine: when they are all that stands between a goal and completion, the run pauses and asks you, and your verdict is labelled as yours rather than presented as verified. A checkpoint along the way that stops on an undecided human-judged criterion asks you for the verdict right there, on the checkpoint panel; a verdict you give at a checkpoint is never asked for again. A criterion you sent back is put to you again once the work has actually changed.
*   **Graded Delegation:** When the main agent delegates a unit of work, it can hand the subagent a scoped definition-of-done. The finished run is graded by an independent evaluator in a fresh context that never saw the subagent's transcript, so the result carries a trusted verdict ("2/3 met", per-criterion) beside the subagent's own unverified summary — the two are always labeled and never conflated. Delegation without criteria behaves exactly as before: no contract, no grade.
*   **Checkpoint Delegation:** When a goal has a checkpoint ladder, Iris can hand the current milestone to a subagent that works it in its own context. The milestone's criteria come straight from the locked contract — the agent cannot restate what it is about to be measured against — and when the subagent finishes, the checkpoint is reached and graded automatically: a clean grade advances without pausing you, exactly as it would for work done directly, and anything contested still stops the ladder for your review. The grade spans every milestone so far, so work that quietly breaks an earlier milestone is still caught.
*   **Checkpoint Auto-Advance:** A goal's criteria can be grouped into an ordered checkpoint ladder, stopping the run for your review at each milestone rather than only at the very end. A checkpoint the independent grader passes cleanly now advances on its own instead of pausing you — a clean grade only means the grader found nothing wrong, not that a human looked, so a grader's mistake advances just as unseen as a correct one. Anything contested still stops the ladder: a criterion the grader found unmet, one it could not verify, a grader that errored or timed out, or a "human-judged" criterion you have not yet decided, which stops the run and asks you for the verdict on the checkpoint panel (Approve stays disabled until every human-judged criterion in that milestone is accepted; Send back consumes a rejection so the agent reworks it), and a verdict you have already given is never asked for twice. Every checkpoint's outcome — auto-advanced, approved, or sent back — is recorded on the conversation rather than on the goal contract, so it survives both the goal ending and a relaunch (it is a column of its own in the conversation database), and each auto-advance also writes a line into the transcript naming the milestone and the evidence it passed on, so the ladder stays inspectable even when nobody stopped to look. Settings → General → Goals turns it off from the next checkpoint on, restoring a pause at every checkpoint after that, alongside how many times the done-gate sends Iris back before a goal finishes without passing.
*   **Session Strip:** A compact, per-session activity strip below the composer — one line per running (or just-finished) session with its role, current activity (thinking, responding, or the tool it's running), elapsed time, and token usage. The toolbar "cpu" badge toggles it between a single main-session line and the full list; clicking a subagent or evaluator row opens a read-only transcript of that session's conversation. Finished sessions linger briefly before aging out. Subagents dynamically self-assign the Easy, Medium, or Hard model tiers based on task complexity.
*   **File Attachments & Vision Routing:** Attach images, PDFs, Word documents, RTF files, and text files via the 📎 button or drag & drop. Vision-capable models process image attachments directly. Non-vision primary models fall back to an auxiliary local/cloud vision model to generate image descriptions. Includes automated document text parsing (PDF/RTF/DocX) and strictly enforced file size limits (20 MB images, 50 MB documents).
*   **Markdown Export & Utilities:** Right-click conversations to archive or unarchive them, copy them to your clipboard as clean, formatted Markdown, or select specific chat turns to copy just those. Archiving is refused while a turn is still running or a goal is active on that conversation; sending anything to an archived conversation — a message, a subagent post-back — brings it back automatically, with two deliberate exceptions: a message from another session is refused instead of un-archiving it, and a job's event card lands silently, because a card starts no turn and an archived conversation is meant to stay idle. A human reopening a conversation is a choice about one thing they picked; a peer doing the same would be expanding its own reach on its own initiative, so it doesn't get to. Automatically renames conversations via the `/rename` command.
*   **Sessions:** Every active conversation (not archived, not a subagent, not a job run's own hidden conversation) is a session that can see and message its peers. The Session Strip above uses "session" more loosely — it also lists subagent and evaluator runs, which are somebody's delegated work rather than peers: they are never listed by `list_sessions` and cannot message anyone. `list_sessions` shows who else is running — name, what they say they're doing, workspace, and busy or idle — but only the busy/idle field is observed by the harness; the name and description are the session's own claim about itself, advertised and unverified, the same way a self-report is not a grade. `send_to_session` wakes a peer with a message framed plainly as a request from another session, free to decline — never as an instruction it's obliged to act on. Archived conversations are not listed and can't be sent to; a peer can't reopen one the way sending a message from you does. A job run's hidden conversation is refused the same way — nobody is reading it and every gated tool inside it fails closed, so it is neither listed nor addressable, and it cannot send either: a background run is offered none of the session tools and a send from one is refused, since delivering it would start a turn under an attended conversation's approval path. A peer-woken chain of messages shares one budget (8 by default) so a session can't spend another session's tokens without bound — only a message you type resets it, never time and never a queued peer message draining on its own.

## 🧠 The Portable Memory & Skill System

Instead of trapping your workflows inside a proprietary database or cloud service, Iris uses the **[Open Knowledge Format (OKF)](https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing)** for its memory and skills layer.

*   **Markdown + YAML:** All long-term memories (`USER.md`, `SOUL.md`) and portable skills (`skills/*.md`) are stored as plain Markdown files with strict YAML frontmatter (OKF).
*   **Knowledge Graphing:** Iris automatically cross-links these files using standard Markdown syntax, creating a navigable knowledge graph on your local filesystem.
*   **Memory Grooming:** The background `/reflect` loop actively grooms the memory library, ensuring frontmatter is up-to-date and repairing broken cross-links.
*   **Project Artifacts:** Generated design docs and research notes are strictly organized into human-readable library trees (e.g., `~/.iris/library/<project_name>/`) instead of opaque UUID directories, and all artifacts enforce the OKF schema for seamless integration.
*   **JIT Prompt Injection:** Iris uses `FactStoreManager` to perform full-text searches against an embedded SQLite fact store (FTS5 with time decay and trust scoring) that sits in between the working context and the static library of markdown "memories" and skills. Facts have a lifecycle: Iris can retract one that turned out wrong, supersede it with a replacement (lineage kept), or restore it, and can rate a retrieved fact helpful or unhelpful to train its trust score. Retrieval itself counts as a usage signal, and a fact that has been used or rated is never evicted by age.
*   **Always-On Custom Rules:** Iris automatically loads any user-defined instruction or rule files inside `~/.iris/rules/` on startup and appends them directly to the base system prompt. This allows you to bootstrap custom behavior rules, environment notes, or stylistic constraints permanently.

### Plugins

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

See [docs/ipf/spec.md](docs/ipf/spec.md) for the normative manifest format
and [docs/ipf/authoring.md](docs/ipf/authoring.md) for a plugin-author
guide with worked examples.

### Core Native Tools
Iris provides some native primitives to the LLM:
1.  `run_command`: Sandboxed execution of shell commands (runs in a lightweight Linux VM via `apple/container` if sandboxing is enabled). Host commands run with the user's login-shell PATH captured at launch, so pyenv/nvm/Homebrew shims resolve even though the command itself isn't run in a login shell.
2.  `read_file`: Reads arbitrary local text files.
3.  `write_file`: Writes/modifies local files.
4.  `schedule_job`: Creates a recurring job in the conversation database: a five-field `cron` expression with an optional IANA `timezone`, an `intervalSeconds` interval, or the loose `minute`/`hour`/`weekday`/`weekdays` fields (`[2,3,4,5,6]` for every weekday). Jobs survive restarts. Each fire runs in the background and reports back with a card in Iris Activity.
5.  `set_workspace`: Automatically binds the active conversation to a project path.
6.  `reflect`: Internal tool allowing the agent to write down its reasoning, plans, and self-evaluations during complex loops.
7.  `goal_complete`: Escapes an active autonomous `/goal` loop.

## 🛠️ Usage

When started, Iris launches as a native macOS App. If you haven't configured your API keys or authentication method, the **Settings Window** will automatically pop up. 
All keys are saved securely to your local Keychain and `UserDefaults`. Gemini supports both standard API Keys and **Application Default Credentials (ADC)** via `gcloud`. See [docs/Google_ADC_credentials.md](docs/Google_ADC_credentials.md) for step-by-step setup and GCP project configuration.

```bash
swift run
```

`swift run` re-signs the binary ad-hoc on every rebuild, and macOS keys Keychain access to the
signature, so each rebuild asks for Keychain access again. With a Developer ID Application
certificate in your keychain, `scripts/run-dev.sh` builds, signs with it, and launches, so one
"Always Allow" sticks across rebuilds. `perf/run.sh` and `scripts/build_release.sh` sign the same
way when the certificate is present (or `CODESIGN_IDENTITY` is set).

### Global Hotkey ⌨️
Iris runs in the background and can be summoned instantly over any other app by pressing **`Cmd + Shift + Space`** (configurable in Settings).

### Slash Commands ⚡

Iris supports in-app slash commands typed directly into the composer. Deterministic commands run instantly in-app without invoking the LLM (zero token cost):

*   **Harness & Models:** `/model [tier|name]` (inspect/switch active model), `/mcp [reload]` (inspect/reconnect MCP servers), `/tokens` (view token usage).
*   **Skills & Bundles:** `/skills [new <name>|reload|show <name>|curate]` (scaffold, list, reload, view, or curate skills), `/bundle [save <name> s1,s2|<name>|clear]` (manage or activate selective skill bundle filters).
*   **Journey & Learning:** `/journey` (render chronological timeline of all learned memories, skills, and facts).
*   **Memory & Rules:** `/rules [reload]` (inspect/reload custom rules), `/facts [all|search <q>|probe <e>]` (query SQLite FactStore; `all` includes retracted and superseded facts), `/search <query>` (full-text search across every saved conversation, archived ones included) — the same index also backs a search field in the sidebar, so conversation search isn't slash-command-only: type into it to see grouped, ranked hits and jump straight to the matching message.
*   **Session Control:** `/new` (fresh chat), `/clear` (clear current buffer; refused in a pinned conversation such as Iris Activity), `/archive` (move this conversation to the archive), `/unarchive` (return it to the active list), `/stop` (cancel active goal/subagents), `/update` (check for GitHub releases). Peer session discovery and messaging (see Sessions, above) have no slash commands of their own — an agent reaches other sessions through `list_sessions`, `send_to_session`, and `set_session_card`, not anything you type.
*   **Autonomous Workflows:** `/goal <desc>` (autonomous execution loop), `/reflect` (memory reflection), `/vibecop init` (generate security rules).

See [docs/slash_commands.md](docs/slash_commands.md) for the full command reference.

### Provider Errors & Retries

When a model call fails, Iris shows a compact red system pill with a one-line headline (provider, HTTP status, and the provider's message). The provider's raw response is available behind a chevron, capped at 2 KB; the full body goes to the console log. Rate limits and overloads (HTTP 429, 503, 529), request timeouts, and lost connections are retried automatically before the error is shown, with a 2 s / 4 s / 8 s backoff (±25% jitter) or the provider's `Retry-After` when it sends one, and each retry is announced as a `[retry]` system line. Each provider request is allowed 180 s before it counts as timed out. With streaming on, a failure before the first token retries exactly as above; a failure after it is shown as `Response interrupted: …` under the partial reply and is not retried.

### Google Workspace Integration 🔐
In the settings window, you can enter your Google OAuth Client ID and Secret, and click **Connect to Google**. Iris will spin up a local listener, redirect you to Google for consent, and seamlessly exchange your authorization code for valid access and refresh tokens.

The **Integrations tab** now includes a collapsible **Setup Guide** that walks you through both the `gcloud` CLI path (recommended) and the Google Cloud Console web path. It auto-detects your gcloud installation, authenticated account, and GCP project, and provides a one-click checklist to enable the six required APIs (Calendar, Drive, Docs, Sheets, Gmail, Tasks). See [docs/google_workspace_oauth_setup.md](docs/google_workspace_oauth_setup.md) for the full walkthrough.

Once connected, Iris has native API access to the following Workspace tools directly from Swift (they are offered to the model only while a Google account is connected, so an unconnected install does not spend prompt tokens on them):
*   **Google Calendar**: `google_calendar_list_events`, `google_calendar_create_event`
*   **Google Docs**: `google_docs_get`
*   **Google Drive**: `google_drive_search`
*   **Google Sheets**: `google_sheets_get`
*   **Google Tasks**: `google_tasks_list_tasklists`, `google_tasks_list_tasks`, `google_tasks_create_task`
*   **Gmail**: `gmail_list_unread`, `gmail_send_email`

### File Attachments & Auxiliary Vision 📎
Iris supports attaching files directly to your prompt using the **📎 attachment button** or via **drag & drop**:
*   **Supported Formats**: Images (`.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`), PDFs (`.pdf`), rich documents (`.docx`, `.rtf`), and text/code files (`.txt`, `.md`, `.json`, `.swift`, `.py`, etc.).
*   **Document Text Parsing**: Text, PDF, and rich text documents are automatically parsed into plain text blocks and appended to the prompt context (up to 100,000 characters per file).
*   **Vision Routing & Auxiliary Configuration**: When attached to vision-capable models (e.g., Gemini 2.0 Flash, Claude 3.5 Sonnet, GPT-4o), images are passed directly in the inline payload. If the active model lacks vision capabilities, Iris automatically routes images to a configured Auxiliary Vision Model (such as local `ollama` with `llava`) to generate detailed image descriptions.
*   **File Size Limits**: Built-in guardrails restrict individual image files to **20 MB** and document/PDF/text files to **50 MB**. Oversized attachments trigger a warning and are safely excluded from memory.

## 🛡️ Vibecop Guardian

Iris includes a reimplementation of [**Vibecop**](https://github.com/bnaylor/vibecop), an independent, paranoid AI guardian (using an auxiliary local model) that evaluates every single terminal command or file operation proposed by the primary agent. 

*   **Auto-Approval**: If the command is completely routine and safe, Vibecop approves it silently, saving you from prompt fatigue.
*   **Guardian Mode**: You can run `/vibecop init` in any workspace. The primary agent will analyze your project and generate a custom `.iris/vibecop.md` file. Vibecop uses this as its system prompt, learning what commands are normal *specifically for this project* (e.g., `go build` is safe here, but `npm` should trigger an escalation).
*   **Escalation**: If the command is destructive, touches restricted paths, or isn't listed in the Guardian config, Vibecop blocks it and escalates to a user confirmation dialog.
*   **Model Flexibility**: Vibecop supports multiple backends — embedded `llama.cpp`, `MLX` for Apple Silicon, cloud providers, and local **Ollama** daemons. When Ollama is selected, Iris auto-probes the daemon to discover installed models, offers a model picker, and can pull the recommended `gemma4:12b` directly from the UI. A clear warning banner is shown if the Ollama daemon is not reachable.

## 📦 Project Setup

Iris is managed via Swift Package Manager (SPM).
To build:
```bash
swift build
```

### Headless Profiling (`--bench`)

The core agent loop runs without the UI, so you can profile end-to-end turn performance
without clicking through the app. Run a benchmark scenario:

```bash
swift run iris --bench                          # built-in default scenario
swift run iris --bench scenarios/echo-latency.json   # a scenario file
swift run iris --bench scenarios/live.json --real    # hit a real provider (needs keys)
```

The binary runs the scenario headlessly and prints a per-category timing breakdown (primary
LLM, tool execution, injection guard, context assembly, …), then exits. Fake scenarios script
the model's responses (with optional simulated latency) and need no network or API keys;
`--real` drives a configured provider for true wall-clock measurement.

Scenario files are JSON. For the full scenario schema, how to read the output, and how to
author new scenarios, see **[docs/headless_profiling.md](docs/headless_profiling.md)**. The
same `ScenarioRunner` powers the profiling tests under
`Tests/irisTests/ProfilingHarnessTests.swift`.

For repeatable performance tracking over time, run `perf/run.sh`: it executes the suites under
`perf/suites/` at a release build, records where each turn's time goes (including a five-rung
comparison against a bare provider call), and compares against promoted baselines. See
[perf/README.md](perf/README.md).

### Updates & Releases

- **Auto-Updates**: Iris automatically checks GitHub Releases for new updates. You can also manually check for updates and view release notes at any time via the **Updates** tab in Settings.
- **Developer & Maintainer Releases**: Instructions for building signed release bundles, publishing releases, and managing release notes can be found in [docs/releasing.md](docs/releasing.md).

### Model Context Protocol (MCP)

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

## 💡 Inspiration

A key bit of Iris's agentic workflow is heavily inspired by the philosophy of [obra/superpowers](https://github.com/obra/superpowers). In particular, we natively enforce the following principles in the agent's system prompt:
*   **Brainstorming First:** The agent must explore context, ask clarifying questions, and propose trade-offs before writing a single line of code.
*   **Design Docs (Specs):** Designs must be presented and approved, then written to `specs/` directories.
*   **Implementation Plans:** Complex designs are broken down into step-by-step plans.
*   **Test-Driven Development (TDD):** The "Iron Law" of testing first. No production code is written without observing a failing test first (RED -> GREEN -> REFACTOR).
*   **Execution Loop:** Implementing code iteratively and reviewing it until the feature matches the specs.
