# Agent Profiles

An agent profile is a named starting point for a conversation: a role, some text added to its system prompt, and (in later builds) the skills it sees, a narrower set of tools, and a model tier. You start a conversation on one from the menu arrow on **New Conversation**. A plain click still starts an ordinary conversation.

## The files

Each profile is one Markdown file in Iris's settings folder, `~/.iris/config/agent-profiles/<name>.md` (`~/.iris-dev/...` for a dev build). **Open Agent Profiles Folder** in the New Conversation menu reveals it in Finder. Iris writes three examples (reviewer, researcher, writer) the first time the folder is created, and never again: one you delete stays deleted.

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

The folder is one Iris protects. The agent can't write a profile without asking you, and no background job can write one at all.

**What applies today:** the system-prompt text and the role. `skills`, `tools` and `tier` are read and kept, and take effect in the next builds.

## A profile only adds and narrows

A profile adds prompt text, picks a role, and (once those builds land) narrows the skills and tools offered and picks a tier. **It never approves, allowlists, grants or unlocks anything**. A profile's tool list is for focus and token cost, not security. What runs without asking is decided only by your allowlist, Vibecop, your approvals, and a job's profile.

Profiles don't apply to the pinned Iris conversation, to a subagent's own conversation, or to a job run.

## A conversation follows its file

A conversation remembers its profile by name, and **the file is the source**. Edit the file and the conversation uses the new version on its next turn, with a system line in the chat saying so, including for an edit made while Iris was closed.
- **The cost:** an edit changes that conversation's system prompt, so its next turn starts a fresh provider prompt cache. That's expected.

**A missing or broken file:** each time the file reads cleanly, Iris keeps a copy of it with the conversation. If the file is deleted, renamed or stops parsing, the conversation keeps using that last good copy, so a narrowed conversation never quietly widens. A system line in the chat says so once and names the parse error, and the sidebar shows the profile as "(last known)".

**Clear Agent Profile** in the conversation's right-click menu removes the profile and its copy. The conversation then runs as an ordinary one. It's the only way to drop a profile. A profile can't be added to an existing conversation (#670).

## Roles

A profile's `role` is the conversation's session role (see [Sessions](sessions.md)), given when the conversation starts. If another active session already holds that role, the new conversation starts with no role, and the chat names the session that holds it. Roles are addresses, so they're never taken from another session automatically. `/role` still works afterwards and changes only the role.

The sidebar shows the profile under the conversation's title, and the role too when it differs from the profile's name.
