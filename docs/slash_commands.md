# Iris Slash Commands Reference

Iris supports in-app slash commands (`/-commands`) typed into the chat composer bar. Commands execute either deterministically (in-app, zero token cost) or trigger system prompts for autonomous agent workflows.

---

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
| `/model` | `/model [fast\|medium\|heavy\|<name>]` | View active model tiers or switch active model for conversation. |
| `/mcp` | `/mcp` | List connected Model Context Protocol (MCP) servers and tools. |
| `/mcp reload` | `/mcp reload` | Reconnect MCP stdio transports and refresh registered tool schemas. |
| `/facts` | `/facts` | View top recent facts stored in the SQLite FactStore. |
| `/facts search` | `/facts search <query>` | Execute an FTS5 full-text search against stored facts. |
| `/facts probe` | `/facts probe <entity>` | Retrieve all facts associated with a specific entity tag. |
| `/search` | `/search <query>` | Full-text search across every saved conversation; lists up to 10 matching messages with their conversation title. |
| `/tokens` | `/tokens` (or `/stats`) | View prompt, candidate, and total token usage breakdown. |
| `/sandbox` | `/sandbox [status\|enable\|disable]` | Inspect or configure the subagent `apple/container` Linux VM runtime. |
| `/new` | `/new` | Create a fresh conversation tab. |
| `/clear` | `/clear` | Clear message history in the current active conversation. |
| `/stop` | `/stop` | Cancel active goal mode or background subagent tasks. |
| `/update` | `/update` | Query GitHub API for the latest Iris release updates. |

---

## 🤖 Agent Workflow Commands (LLM Prompts)

| Command | Usage | Description |
|---|---|---|
| `/goal` | `/goal <description>` | Activate an autonomous goal-driven loop. Iris executes tools until complete. |
| `/reflect` | `/reflect` | Trigger manual memory reflection, fact consolidation, and OKF frontmatter grooming. |
| `/vibecop init` | `/vibecop init` | Analyze active workspace and generate `.iris/vibecop.md` security rules. |
| `/rename` | `/rename` | Automatically analyze conversation history and assign a 1–4 word title. |
