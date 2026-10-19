# Agent Profiles

An agent profile is a named starting point for a conversation: a role, some text added to its system prompt, a narrower set of tools, the skills it sees, and a model tier. You start a conversation on one from the profile button beside **New Conversation**, at the foot of the sidebar; **New Conversation** itself still starts an ordinary one. The menu shows each profile's role when it differs from its name.

## The files

Each profile is one Markdown file in Iris's settings folder, `~/.iris/config/agent-profiles/<name>.md` (`~/.iris-dev/...` for a dev build). **Open Agent Profiles Folder** in that menu reveals it in Finder. Iris writes three examples (reviewer, researcher, writer) the first time the folder is created, and never again: one you delete stays deleted.

```markdown
---
role: reviewer            # optional; becomes the conversation's session role
tier: hard                # optional; easy | medium | hard
skills: [code-review]     # optional; omitted = your usual skills
tools: [read_file, run_command]   # optional; omitted = the usual tools
---
You review pull requests for this repository. Read the whole diff first, ...
```

- **The name** is the file name, with lowercase letters, digits and dashes. A `name:` line, if present, must match it.
- **The body** below the frontmatter is added to the system prompt, under `# Agent Profile: <name>`.
- **Lists** can be written inline (`[a, b]`) or one `- a` per line.
- **Errors:** a file that doesn't parse shows in the menu as unusable, with the reason.
- **Names that match nothing:** a name in `tools:` or `skills:` that isn't one of Iris's tools, one of your MCP servers (`mcp:<name>`) or tools, or one of your skills is ignored. The menu marks such a profile "(unknown names)" and lists them on hover, and a conversation started on it says so once, so a typo doesn't quietly leave a conversation with fewer tools than you meant.

The folder is one Iris protects. The agent can't write a profile without asking you, and no background job can write one at all.

**What applies:** all of it: the system-prompt text, the role, `tools`, `skills` and `tier`.

## Skills and tier

- **`skills:`** replaces your usual skill list (and any `/bundle`) for that conversation: the model is shown only those skills. A name that isn't one of your skills is simply not listed. Without `skills:`, the conversation sees your usual skills.
- **`tier:`** is the model tier the conversation runs on (easy, medium or hard, each the model Settings → Models names for it).
- **`/model easy|medium|hard`** in a conversation sets that conversation's own tier, which wins over the profile's; `/model default` clears it again, back to the profile's tier or the usual default. `/model` alone says which tier the conversation is on and why. A subagent keeps the tier its delegation asked for.
- **The PRI light's details** name the model the current conversation runs on, and where its tier came from.

## Tools

With a `tools:` list, a conversation is offered only those tools, and a call to any other is refused with a line naming the profile. Without one, it gets the usual tools.
- **MCP and plugin tools** are named as the model sees them. `mcp:<server>` stands for every tool that server offers.
- **Always kept:** the tools `/goal` and `/rename` work through (`goal_complete`, `propose_goal_contract`, `rename_conversation`, `reach_checkpoint`, `amend_goal_contract`, `delegate_milestone`, `waive_criterion`), and `schedule_next_tick`, which paces a self-paced `/loop`. They're offered only during their own flow anyway.
- **Messaging other sessions** (`send_to_session`, `list_sessions` and the rest) isn't kept: list those tools if the profile should talk to peers.
- **Memory reflection still works.** On the turn where Iris consolidates memory, the tools that turn uses (`update_soul`, `update_user_profile`, `update_memory`, `create_skill`, `update_skill`) stay offered. They write the same memory any conversation does.
- **Subagents** a profiled conversation starts get the same narrowing, at any depth, so delegating can't go around it. The goal grader keeps its own tools.

## A profile only adds and narrows

A profile adds prompt text, picks a role, narrows the tools and skills offered, and picks a tier. **It never approves, allowlists, grants or unlocks anything**. A profile's tool list is for focus and token cost, not security. What runs without asking is decided only by your allowlist, Vibecop, your approvals, and a job's profile.

Profiles don't apply to the pinned Iris conversation, to a subagent's own conversation, or to a job run.

## A conversation follows its file

A conversation remembers its profile by name, and **the file is the source**. Edit the file and the conversation uses the new version on its next turn, with a system line in the chat saying so, including for an edit made while Iris was closed.
- **The cost:** an edit changes that conversation's system prompt, so its next turn starts a fresh provider prompt cache. That's expected.

**A missing or broken file:** each time the file reads cleanly, Iris keeps a copy of it with the conversation. If the file is deleted, renamed or stops parsing, the conversation keeps using that last good copy, so a narrowed conversation never quietly widens. A system line in the chat says so once and names the parse error, and the sidebar shows the profile as "(last known)".

**Clear Agent Profile** in the conversation's right-click menu removes the profile and its copy. The conversation then runs as an ordinary one. It's the only way to drop a profile. A profile can't be added to an existing conversation (#670).

## Roles

A profile's `role` is the conversation's session role (see [Sessions](sessions.md)), given when the conversation starts. If another active session already holds that role, the new conversation starts with no role, and the chat names the session that holds it. Roles are addresses, so they're never taken from another session automatically. `/role` still works afterwards and changes only the role.

The sidebar shows the profile under the conversation's title, and the role too when it differs from the profile's name.
