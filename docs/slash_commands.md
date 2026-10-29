# Iris Slash Commands Reference

Iris supports in-app slash commands (`/-commands`) typed into the chat composer bar. Commands execute either deterministically (in-app, zero token cost) or trigger system prompts for autonomous agent workflows.

---

## At a glance

Moved from the feature tour ([docs/features.md](features.md)), word for word (#534); it carries a few details the tables below leave out.

Iris supports in-app slash commands typed directly into the composer. Deterministic commands run instantly in-app without invoking the LLM (zero token cost):

*   **Harness & Models:** `/model [easy|medium|hard|default]` (show this conversation's tier, or set it), `/mcp [reload]` (inspect/reconnect MCP servers), `/tokens` (view token usage).
*   **Skills & Bundles:** `/skills [new <name>|reload|show <name>|curate]` (scaffold, list, reload, view, or curate skills), `/bundle [save <name> s1,s2|<name>|clear]` (manage or activate selective skill bundle filters).
*   **Journey & Learning:** `/journey` (render chronological timeline of all learned memories, skills, and facts).
*   **Memory & Rules:** `/rules [reload]` (inspect/reload custom rules), `/facts [all|search <q>|probe <e>]` (query SQLite FactStore; `all` includes retracted and superseded facts), `/search <query>` (full-text search across every saved conversation, archived ones included) — the same index also backs a search field in the sidebar, so conversation search isn't slash-command-only: type into it to see grouped, ranked hits and jump straight to the matching message.
*   **Session Control:** `/new` (fresh chat; in Iris it rotates instead: a reflection pass, then a fresh pinned Iris that opens with a summary of the old one, which is archived as "Iris — until ‹date›" and stays readable through `search_conversations`/`read_conversation`. Refused while a turn is running or a goal is active there. Esc stops it: before the new Iris exists, Iris is not rotated (a reflection already under way may have updated memory); after, the rotation finishes without a summary. Nothing rotates automatically — once Iris's own history runs past about 150k estimated tokens, it posts a one-line suggestion to run `/new`, once per crossing, and never while a rotation is already running; you decide when to reset), `/clear` (clear current buffer; refused in a pinned conversation such as Iris), `/archive` (move this conversation to the archive; refused on Iris itself — `/new` archives Iris by rotating it), `/unarchive` (return it to the active list), `/stop` (cancel active goal/subagents; like Esc or Stop, it also stops the conversation's background subagents, which come back `cancelled` without starting a turn), `/update` (check for a new version; installed release app only). `/role [<name>|clear]` shows this session's role, assigns one, or releases it (see [Sessions](sessions.md)); peer session discovery and messaging are otherwise still the agent's own tools — it reaches other sessions through `list_sessions`, `describe_session`, `send_to_session`, and `set_session_card`, not anything you type.
*   **Autonomous Workflows:** `/goal <desc>` (autonomous execution loop), `/loop [interval] <prompt>` (re-run a prompt on a cadence, or self-paced), `/reflect` (memory reflection), `/vibecop init` (generate security rules).

The full reference follows.

## ⚡ Deterministic Harness Commands (Zero LLM Tokens)

| Command | Usage | Description |
|---|---|---|
| `/skills` | `/skills` | List all registered skills and memory tools. |
| `/skills new` | `/skills new <name>` | Scaffold a structured OKF `SKILL.md` template for a new skill. |
| `/skills reload` | `/skills reload [name]` | Invalidate system prompt cache and reload skill definitions from disk. |
| `/skills show` | `/skills show <name>` | Display the full `SKILL.md` body for a given skill. |
| `/skills curate` | `/skills curate` | Run skill health pass, soft-delete corrupt skills to trash, and write `~/.iris/memory/curator/REPORT.md`. |
| `/bundle` | `/bundle [save <name> s1,s2\|<name>\|clear]` | List, save, activate, or clear selective skill bundle context filters. |
| `/journey` | `/journey` | Render chronological timeline of all learned skills, profile evolutions, and facts. |
| `/rules` | `/rules` | View loaded custom rules from `~/.iris/rules/`. |
| `/rules reload` | `/rules reload` | Force system prompt cache invalidation to re-read custom rule files. |
| `/model` | `/model [easy\|medium\|hard\|default]` | Alone: which tier this conversation runs on, the model it names, and why (set by `/model`, from its [agent profile](agent_profiles.md), or the default), plus the three tiers' models. With a tier (`fast` and `heavy` also work), sets this conversation's tier from its next turn, and only this conversation's; `default` clears it. A model name isn't accepted: models are set per tier in Settings → Models. |
| `/mcp` | `/mcp` | List connected Model Context Protocol (MCP) servers and tools. |
| `/mcp reload` | `/mcp reload` | Reconnect MCP stdio transports and refresh registered tool schemas. |
| `/facts` | `/facts` | View top recent facts stored in the SQLite FactStore. |
| `/facts search` | `/facts search <query>` | Execute an FTS5 full-text search against stored facts. |
| `/facts probe` | `/facts probe <entity>` | Retrieve all facts associated with a specific entity tag. |
| `/search` | `/search <query>` | Full-text search across every saved conversation; lists up to 10 matching messages with their conversation title. |
| `/tokens` | `/tokens` (or `/stats`) | View prompt, candidate, total, cache read, and cache write token usage breakdown (5a; a cache figure never reported by the provider shows as `—`, not zero). |
| `/sandbox` | `/sandbox [status\|enable\|disable]` | Inspect or configure the subagent `apple/container` Linux VM runtime. |
| `/new` | `/new` | Create a fresh conversation tab. In Iris (the pinned conversation) it rotates instead: a reflection pass, then a fresh pinned Iris opening with a summary of the old one, which is archived as "Iris — until ‹date›". Refused there while a turn is running or a goal is active. Rotation is never automatic — once Iris's history passes about 150k estimated tokens, it posts a one-line suggestion to run `/new`, once per crossing, and not while a rotation is already running. |
| `/clear` | `/clear` | Clear message history in the current active conversation. Refused in a pinned conversation (Iris). |
| `/archive` | `/archive` | Move this conversation to the archive. Refused while a turn is running or a goal is active on it, and refused on Iris itself — `/new` archives Iris by rotating it. |
| `/unarchive` | `/unarchive` | Return this conversation to the active list. |
| `/jobs` | `/jobs` | List background jobs — trigger, next fire, last status — plus a line per unacknowledged failure. |
| `/jobs ack` | `/jobs ack <run id>` | Mark a failed or blocked run as seen; takes a full run id or the first eight or more characters of one. |
| `/jobs reschedule` | `/jobs reschedule <name> <cron> [timezone]` | Give a scheduled or polled job (built-ins such as the daily digest included) a new five-field cron and report its next fire. Quote names or crons with spaces: `/jobs reschedule "Daily digest" "0 9 * * *"`. An invalid cron changes nothing; a directory watch is refused. |
| `/jobs delete` | `/jobs delete <name>` | Delete a job and its ledger rows. Refused while one of its runs is in flight. |
| `/jobs exempt` | `/jobs exempt <name> <tool>` · `/jobs unexempt <name> <tool>` | Add or remove one outbound tool from a mutating job's exemptions, so its runs may call it without asking even after reading untrusted content ([Jobs](jobs.md#outbound-sends-after-untrusted-content)). Adding one says what it lets the job do; a read-only job, or a tool that isn't outbound, is refused. |
| `/jobs url` | `/jobs url <name> [on\|off]` | `on` mints a link (`iris://run-job/<token>`) that fires the job, shown once in a sheet and never saved; `on` again replaces it, `off` retires it, and the bare form says whether it is on. Changing the job's prompt, profile or policy, or a model lifting your pause, turns it off. Opening the link fires the job; a link that launches Iris starts it with no window, and its card lands in Iris once it has finished starting. While a `--run-job` holds the store, Iris waits for that run first, behind a small "Iris is waiting" notice. |
| `/role` | `/role [<name>\|clear]` | Show this session's role, assign one (lowercase letters, digits and `-`, 1-32 characters; `iris` and `clear` are reserved), or release it. Assigning an already-held role moves it here instead; the previous holder is told and loses its skills. Refused on the pinned Iris. A conversation started on an [agent profile](agent_profiles.md) gets the profile's role, unless another session holds it; `/role` changes only the role, never the profile. |
| `/stop` | `/stop` | Cancel active goal mode or background subagent tasks. |
| `/update` | `/update` | Check for a new version of Iris with Sparkle (installed release app only; dev builds reply that updates are disabled). |

---

## 🤖 Agent Workflow Commands (LLM Prompts)

| Command | Usage | Description |
|---|---|---|
| `/goal` | `/goal <description>` | Activate an autonomous goal-driven loop. Iris executes tools until complete. |
| `/loop` | `/loop [interval] <prompt>` | Re-run a prompt in this conversation every interval (1m to 24h), as a turn you can watch and talk to. With no interval it's self-paced: the first tick comes in a minute, and each tick Iris picks the wait before the next (1m to 1h, with `schedule_next_tick`), falling back to 20 minutes when it doesn't pick. A self-paced prompt can't start with a number (that reads as a mistyped interval) or with a command word like `stop` or `pause`; put a word in front, or an interval. `/loop stop`, `/loop pause`, `/loop resume`; `/loop` alone shows it. Stops after the Loop tick limit (Settings, default 50). Each tick resends the whole conversation, since Iris doesn't compact history, so it costs a little more each time. Comes back paused after a relaunch. Refused on Iris itself, and while a `/goal` runs (and `/goal` while a loop runs). Not a job: for something that runs with nobody watching, use a scheduled job. [Spec](specs/2026-10-19-loop.md) |
| `/reflect` | `/reflect` | Trigger manual memory reflection, fact consolidation, and OKF frontmatter grooming. |
| `/vibecop init` | `/vibecop init` | Analyze active workspace and generate `.iris/vibecop.md` security rules; writing it asks you, and its rules take effect once you trust them under Review Workspace Rules (#617, #625). |
| `/rename` | `/rename` | Automatically analyze conversation history and assign a 1–4 word title. Refused on Iris itself, which keeps its name. |
