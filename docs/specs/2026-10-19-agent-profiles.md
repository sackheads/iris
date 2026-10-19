# Agent profiles (#465)

**Status:** spec, iris-dev-1, 2026-10-19. Brian picked this from the list ("i like the list starting with profiles"). The planner's starting rulings came in its brief, and its rulings on forks A, B and C (all option 1) are recorded where each fork was.

## What it is

An *agent profile* is a named starting point for a conversation: a role, a system-prompt addition, the skills it sees, a narrower tool list, and a model tier. You choose one when you start a conversation, from a menu on **New Conversation**, and the sidebar row shows it. The inspiration is bnaylor/ka-overseer's `role-examples/`: plain Markdown roles with a starting prompt. This adds just enough structure for Iris to act on it.

**v1 never widens anything.** A profile can't approve, allowlist, grant, mount or unlock anything. It can only add prompt text, pick skills, *narrow* the tools offered, and pick a tier. That keeps it off the approval boundary (planner's ruling).

## Name

"Profile" is taken twice already: `JobProfile` (`readOnly`/`mutating`, the `profile` argument on `schedule_job`) and "User Profile" (USER.md, `update_user_profile`). So:
- **UI:** "agent profile", never bare "profile".
- **Code:** `AgentProfile`, `AgentProfileStore`, and `Conversation.agentProfile`. Bare `profile` is never used for this.
- *Considered and rejected:* "preset", which reads as settings, not a role, and "persona", which already describes the subagent `role` argument.

## Files

One Markdown file per profile, at **`~/.iris/config/agent-profiles/<name>.md`**. The dev home is `~/.iris-dev/...`, and the seeder copies it with the rest of `config/`.

```markdown
---
name: reviewer            # optional; defaults to the file name. [a-z0-9-], at most 32 characters
role: reviewer            # optional; becomes the conversation's session role (see Roles)
tier: hard                # optional; easy | medium | hard
skills: [code-review, swift-testing]   # optional; omitted = the usual skills
tools: [read_file, run_command, search_web]   # optional; omitted = the usual tools
---
You review pull requests for this repository. Read the diff, run the touched tests, …
```

- **The body is the system-prompt addition.** Frontmatter is parsed with the existing `SkillFrontmatter` reader. A file that doesn't parse shows in the picker as unusable, with its error, and can't be chosen.
- **Why `config/`:** it's a protected write directory (`IrisPaths.protectedWriteDirs`). The agent's `write_file` there always asks the person, and a background run can never write it. A profile is text that steers the model, so editing it should need a person, just as `rules/` is the person's to edit. `memory/` would be auto-allowed for attended writes.
- **Shipped examples:** a few example files (reviewer, researcher, writer), installed once like the shipped skills and never overwritten.

## A conversation links to its profile by name

`Conversation.agentProfile: String?` holds the **name**, not a snapshot. The file is read when it's used, so editing the file changes the conversation's next turn.
- **Why not a snapshot:** the file is something you tune as you use it, and a snapshot would freeze every existing conversation on the old text with no way to update it.
- **The prompt cache:** the composed prompt is keyed by the profile's name and a hash of the file's content, so an unchanged file keeps the provider prompt cache warm. The modification time isn't used: it can miss an edit made within the same second.
- **Editing a profile costs a cache prefix.** Because the link is live, an edit changes the system prompt on that conversation's next turn, which starts a new prompt-cache prefix. That's expected, and `docs/agent_profiles.md` will say so, so the cost isn't a surprise.
- **A profile's tool list is for focus and token cost, not security.** Permissions come only from the approval ladder (allowlist, Vibecop, the person) and from job profiles. The spec and `docs/agent_profiles.md` both say so plainly. The last-known-good fallback below keeps a narrowed chat from widening by surprise, but it doesn't turn `tools:` into a permission.
- **Missing or unreadable file** (deleted, renamed, broken frontmatter): **the file wins whenever it reads, and a last-known-good copy is only the fallback** (planner's ruling after dev-2's review). Each time the conversation reads its profile successfully, and the content hash differs from the stored copy, it saves the parsed profile (prompt, tools, skills, tier) on the conversation. While the file can't be read, the conversation keeps using that copy, so a narrowed chat never widens silently. The chat says so once: "Agent profile `reviewer` couldn't be read (line 3: tools must be a list); this conversation keeps using the last version it read. To drop the profile, use Clear Agent Profile." The sidebar label shows "(last known)".
- **Clear Agent Profile** is a context-menu item on a profiled conversation. It removes the profile and its saved copy, so the conversation becomes a plain one. Widening happens only through that explicit action, and it's the only way to drop a profile whose file is gone. It's in v1 because it's narrower than Fork C (applying a profile), and without it, deleting the file would leave the copy in force for good.

## Roles

Session roles (#469/#480) already exist: `Conversation.role`, user-assigned with `/role`, unique among active sessions, used for peer addressing and the identity section. A profile **doesn't add a second role concept.** Its `role:` is the conversation's session role, set once at creation through the same `SessionRoles` rules.
- **Ruled (Fork A, option 1):** if another active session already holds the role, the conversation starts with no role. The notice names the session that holds it, and the sidebar label still shows the profile's name. Roles are unique so that `role:` addressing is never ambiguous, and an automatic suffix would quietly break that.
- `/role` still works afterwards and changes only the role, not the profile.

## What the profile changes, and where

**There is one main `IrisEngine` for every attended conversation** (`AppState.swift:1392`). So nothing can be stored on the engine: each turn resolves the conversation's profile from its `conversationId`.

| Part | Where | How |
|---|---|---|
| **System-prompt addition** | `assembledSystemPrompt(workspacePath:)` | A layer after USER.md and AGENTS.md: `# Agent Profile: <name>` plus the body. The cache key gains the profile's name and content hash. |
| **Skills** | the `# Available Skills` block in the base prompt | A per-conversation skill list, in the same shape as a skill bundle. It **replaces** the global `/bundle` for that conversation. The base prompt is currently cached once per engine, so it becomes a map on the actor, keyed by skills selection (default, or a profile's list), and invalidation clears the map. |
| **Tools** | `processInputBody`, the tool pipeline | Intersect with the profile's `tools`. This runs **after** the sticky union and `hardStrip`, so a sticky tool can't widen a profile (5c). A call to a tool outside the list is refused at dispatch, like `profileRefusal`. |
| **Tier** | the three `modelTier` reads in `iris.swift` | Resolved per turn: the conversation's own tier (set by `/model`, #667), else the profile's, else the engine's. |

- **Ruled (Fork B, option 1): flow tools are exempt from a profile's narrowing.** That covers `goal_complete`, `propose_goal_contract`, `rename_conversation`, `reach_checkpoint` and `amend_goal_contract`. They're already gated to their trigger or state (Invariant 6), so narrowing them would break `/goal` and `/rename` in a profiled chat without saving any tokens. `send_to_session` isn't a flow tool and is narrowed like any other: a profile without it can't message peers.
- **MCP and plugin tools** are named in `tools:` by their declared names, exactly as the model sees them. `mcp:<server>` stands for every tool that server declares.
- **Unknown names:** a name in `tools:` that isn't a tool is ignored and listed in the picker's details. So is a name in `skills:` that isn't a skill.

## Invariant 6 and token cost

- **Cost:** a profile with `tools:` *reduces* declaration tokens on every turn, and a short `skills:` list shrinks the skills block. The prompt addition costs its own length.
- **No profile:** a conversation without one is byte-for-byte unchanged.

## What a profile never touches

- **The pinned Iris conversation:**
  - it never gets a profile;
  - the picker isn't offered for it;
  - `/new` rotation in Iris doesn't apply one;
  - a stored value on the pinned conversation is ignored when loaded, as `mayHoldRole` does for roles.
- **Subagents and the evaluator:** a subagent doesn't inherit the profile's prompt, skills or tier, and keeps its own role prompt (#668). It **does** inherit the tool narrowing: its tools are intersected with the profile's `tools:`, so delegation can't go around it. The grader keeps its own toolset, which a profile doesn't touch.
- **Job runs:** no profile in v1, because a job's hidden conversation is created by the runner.
- **Approvals:** none of the above reaches `requestApprovalSource`.

## UI

- **New Conversation** becomes a split button. Clicking it starts a plain conversation, as today. Its menu triangle lists the agent profiles: name, role, and the first line of the body, plus unusable ones greyed out with their error. It ends with **Open Agent Profiles Folder**, which reveals the folder in Finder and creates it if missing.
- **The sidebar row** gets a secondary line in the style of the "home writable by the sandbox" label: `◆ reviewer`. The role is shown after it when it differs from the profile's name, and "(missing)" when the file is gone.
- **Ruled (Fork C, option 1):** a profile is chosen at creation only in v1. Applying one to an existing conversation is filed as #670. The reason is scope: switching a conversation's profile also has to decide its role and tier mid-session. It isn't that the prompt changes mid-history, because the live link already does that when the file is edited. Such an edit is noted in the chat: "Agent profile `reviewer` changed; this turn uses the new version."

## Persistence (Invariant 1)

- **Model:** `Conversation.agentProfile: String?` (the name) and `Conversation.agentProfileSnapshot: AgentProfileSnapshot?` (the last-known-good parse: prompt, tools, skills, tier, content hash). Both are read with `decodeIfPresent` and have `CodingKeys` cases. The snapshot is written only when the content hash changes, not on every turn.
- **Store:**
  - a `ConversationStore` migration `v23_agent_profile` adding two columns (the name, and the snapshot as JSON text);
  - `upsertMetadata`, both the UPDATE and the INSERT;
  - `loadAll`'s row read.
- **Tests:**
  - a round-trip test ("the name and snapshot persist with the conversation, and a row from before #465 reads as none");
  - deleting the file keeps the snapshot in use with a notice;
  - Clear Agent Profile removes both.

## Build PRs (each opened as a draft, reviewed by iris-dev-2)

1. **User-visible first:**
   - the files and `AgentProfileStore` (parse, list, stamp);
   - the New Conversation picker and the sidebar label;
   - the persisted reference;
   - the **system-prompt addition** and the role at creation;
   - the pinned exclusion;
   - Open Agent Profiles Folder, and the shipped examples;
   - the last-known-good snapshot and **Clear Agent Profile**.
   - **Closes #668**, with one invalidation rule for every prompt built from something other than the default. An engine whose base prompt was set from custom text (a subagent's role prompt, through `setSystemPrompt`) keeps that text and rebuilds from it when invalidated, never from SOUL.md and the default skills. A profiled conversation's addition is a layer above the base, so a skill change rebuilds it with the profile still in place.
   - **Tests:** a subagent that writes a skill still sends its role prompt on its next turn, and a profiled conversation still sends its profile's addition after a skill change.
2. **Tools:** intersection after the sticky union and `hardStrip`, the dispatch refusal, and the Fork B exemptions.
3. **Skills and tier:** the per-conversation skills selection (the base-prompt cache keyed by it) and the per-turn tier.
   - **Closes #667:** `/model easy|medium|hard` sets *that conversation's* tier, through the same per-turn resolution, not the shared engine's. Its reply names the model the conversation will now use.
   - **Test:** after `/model`, the next turn's request goes to that tier's model.

## Docs (Invariant 9)

- **New page:** `docs/agent_profiles.md`, linked from `docs/features.md`. It explains the file format, what a profile can and can't change, and missing files.
- **`docs/slash_commands.md`:** `/role`'s relation to a profile.
- **Agent-facing:** the identity section names the profile.
- **README:** no change (it's only for the front-page pitch), unless Brian wants this to replace a "Why it's worth a look" bullet.
