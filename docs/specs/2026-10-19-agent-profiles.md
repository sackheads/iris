# Agent profiles (#465)

**Status:** draft spec, iris-dev-1, 2026-10-19. Brian picked this from the list ("i like the list starting with profiles"). The planner's starting rulings are in its brief; the forks still open are marked **Fork**.

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
- **The prompt cache:** the composed prompt is keyed by the profile's name and the file's modification stamp, so an unchanged file keeps the provider prompt cache warm.
- **Missing or unreadable file** (deleted, renamed, broken frontmatter): the conversation runs as a conversation without a profile. The chat says so once ("Agent profile `reviewer` isn't there any more; this conversation runs without it"), and the sidebar label shows "(missing)". This is safe because v1 profiles only narrow: losing one never widens past what an ordinary conversation already has.

## Roles

Session roles (#469/#480) already exist: `Conversation.role`, user-assigned with `/role`, unique among active sessions, used for peer addressing and the identity section. A profile **doesn't add a second role concept.** Its `role:` is the conversation's session role, set once at creation through the same `SessionRoles` rules.
- **Fork A:** what happens when the role is already held by another active session?
  - **(1)** The conversation starts with no role, and the chat says why. *(Recommended: roles are addresses, and an automatic `reviewer-2` would make peers guess.)*
  - **(2)** Add a numeric suffix.
- `/role` still works afterwards and changes only the role, not the profile.

## What the profile changes, and where

**There is one main `IrisEngine` for every attended conversation** (`AppState.swift:1392`). So nothing can be stored on the engine: each turn resolves the conversation's profile from its `conversationId`.

| Part | Where | How |
|---|---|---|
| **System-prompt addition** | `assembledSystemPrompt(workspacePath:)` | A layer after USER.md and AGENTS.md: `# Agent Profile: <name>` plus the body. The cache key gains the profile's name and stamp. |
| **Skills** | the `# Available Skills` block in the base prompt | A per-conversation skill list, in the same shape as a skill bundle. It **replaces** the global `/bundle` for that conversation. The base prompt is currently cached once per engine, so it becomes cached per skills selection (default, or per profile). |
| **Tools** | `processInputBody`, the tool pipeline | Intersect with the profile's `tools`. This runs **after** the sticky union and `hardStrip`, so a sticky tool can't widen a profile (5c). A call to a tool outside the list is refused at dispatch, like `profileRefusal`. |
| **Tier** | the three `modelTier` reads in `iris.swift` | Resolved per turn: the profile's tier, else the engine's. This is also where #667's fix (`/model` never sets the tier) belongs. |

- **Fork B:** tools the harness itself relies on (`goal_complete`, `propose_goal_contract`, `rename_conversation`, `reach_checkpoint`, `amend_goal_contract`, `send_to_session` replies).
  - **(1)** Always exempt from the profile's narrowing, because `/goal`, `/rename` and the goal loop would break without them, and they're already gated to their flows (Invariant 6). *(Recommended.)*
  - **(2)** Narrowed like any tool.
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
- **Subagents and the evaluator:** they don't inherit the delegating conversation's profile. A subagent keeps its own role prompt (#668 tracks a bug there), and the grader keeps its own toolset.
- **Job runs:** no profile in v1, because a job's hidden conversation is created by the runner.
- **Approvals:** none of the above reaches `requestApprovalSource`.

## UI

- **New Conversation** becomes a split button. Clicking it starts a plain conversation, as today. Its menu triangle lists the agent profiles: name, role, and the first line of the body, plus unusable ones greyed out with their error. It ends with **Open Agent Profiles Folder**, which reveals the folder in Finder and creates it if missing.
- **The sidebar row** gets a secondary line in the style of the "home writable by the sandbox" label: `◆ reviewer`. The role is shown after it when it differs from the profile's name, and "(missing)" when the file is gone.
- **Fork C:** applying a profile to an *existing* conversation.
  - **(1)** No for v1: chosen at creation only. *(Recommended: changing the prompt, tools and tier mid-history makes earlier turns misleading, and Brian's description is "when starting a conversation".)*
  - **(2)** A context-menu item.

## Persistence (Invariant 1)

- **Model:** `Conversation.agentProfile: String?`, read with `decodeIfPresent`, plus a `CodingKeys` case.
- **Store:**
  - a `ConversationStore` migration `v23_agent_profile` adding a column;
  - `upsertMetadata`, both the UPDATE and the INSERT;
  - `loadAll`'s row read.
- **Test:** a round-trip test ("persists with the conversation, and a row from before #465 reads as none").

## Build PRs (each opened as a draft, reviewed by iris-dev-2)

1. **User-visible first:**
   - the files and `AgentProfileStore` (parse, list, stamp);
   - the New Conversation picker and the sidebar label;
   - the persisted reference;
   - the **system-prompt addition** and the role at creation;
   - the pinned exclusion;
   - Open Agent Profiles Folder, and the shipped examples.
2. **Tools:** intersection after the sticky union and `hardStrip`, the dispatch refusal, and the Fork B exemptions.
3. **Skills and tier:** the per-conversation skills selection (the base-prompt cache keyed by it) and the per-turn tier, which fixes #667 on the way.

## Docs (Invariant 9)

- **New page:** `docs/agent_profiles.md`, linked from `docs/features.md`. It explains the file format, what a profile can and can't change, and missing files.
- **`docs/slash_commands.md`:** `/role`'s relation to a profile.
- **Agent-facing:** the identity section names the profile.
- **README:** no change (it's only for the front-page pitch), unless Brian wants this to replace a "Why it's worth a look" bullet.
