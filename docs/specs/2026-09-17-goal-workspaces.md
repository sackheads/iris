# Goal Workspaces — Design

* **Issues**: [#68](https://github.com/sackheads/iris/issues/68) (goals should not run in the process cwd). Unblocks the trust story for **D1** ([2026-09-14-deterministic-done-gates.md](2026-09-14-deterministic-done-gates.md)) and gives [#61](https://github.com/sackheads/iris/issues/61) (resume) a stable home.
* **Date**: 2026-09-17
* **Status**: Implemented (2026-09-17). The design below is as-built; deviations are noted in §11.

## 1. Overview

A conversation with no bound workspace runs `run_command` without setting `currentDirectoryURL`, so the agent works in the **process cwd** — under `swift run`, the Iris source repo. `/goal write a hangman game in python` builds `hangman.py` inside the Iris tree, and the evaluator then grades "is the game playable?" amid a hundred thousand lines of unrelated Swift.

Slice C made the evaluator *consistent* with the agent (same directory, fenced to it), which stopped it roaming. But consistency is not correctness: both are in the wrong place.

**D1 raised the stakes.** The done-gate now refuses completion based on the grader's verdict, and the grader re-runs each `executable` criterion. A criterion like `swift test` is currently evaluated against the Iris repo regardless of what the agent did — so the gate blocks or passes on evidence that has nothing to do with the goal. Everything from A through D1 assumes verdicts mean something; this is the slice that makes the directory under them correct.

**The one-line version:** a goal gets its own home, chosen where the user is already reviewing the contract.

## 2. Scope

Binding happens **at contract lock**, for **contracted goals only**.

- **An existing binding always wins.** `set_workspace`, or a workspace already on the conversation, is never overridden.
- **Contract-less goals are untouched.** A plain `setGoal` keeps today's behaviour; it has no draft panel in which to show or edit a choice, and D1 does not gate it.
- **Subagents are untouched.** They inherit the parent's workspace (slice B3) and get whatever the parent resolved.
- **Checkpoints are untouched.** The ladder does not rebind anything.

**Explicitly deferred (deliberate, not silent omissions):**
- **Garbage collection of `~/.iris/workspaces` → its own issue.** Goals will accumulate directories. Deleting a goal's artifacts is destructive and needs its own argument about retention and user consent; it is not going in the slice that creates them.
- **Migrating existing conversations → out of scope.** A conversation that already ran in the cwd stays as it is. Rebinding it retroactively would move nothing and would misrepresent where its artifacts actually are.
- **Changing `set_workspace` → out of scope.** It remains the explicit way to bind, and it still wins.

## 3. The draft carries a workspace

`propose_goal_contract` gains one optional parameter:

```
workspace: STRING?   // where this goal should run
```

`GoalContract` gains `var workspace: String?`, `decodeIfPresent`-defaulted — a contract persisted before this slice has no such key, and a synthesized decode would throw `keyNotFound` and fail the whole `[Conversation]` decode, dropping every conversation.

The draft panel shows the **resolved** workspace as an editable row beside the criteria. Putting it in the draft means it passes through the approval gate that already exists, rather than adding a new prompt to every goal. It also lets the model do the thing it is actually good at here: reading "fix the parser bug in ~/src/foo" and proposing `~/src/foo`, versus reading "write a hangman game" and proposing nothing.

## 4. Resolution

One pure function, so the rule is testable without a filesystem or a view:

```swift
enum WorkspaceResolution: Equatable {
    case existing(String)      // bind a directory that is already there
    case created(String)       // create and bind a fresh one under ~/.iris/workspaces
    case keptExisting(String)  // the conversation was already bound; nothing changes
}

func resolveGoalWorkspace(proposed: String?, objective: String,
                          existingBinding: String?, directoryExists: (String) -> Bool)
    -> WorkspaceResolution
```

In order:

1. **`existingBinding != nil`** → `.keptExisting`. The user or the agent already chose; this slice does not second-guess it.
2. **`proposed` expands to a directory that exists** → `.existing`. Pointing at real code requires that code to be there.
3. **Otherwise** — `proposed` nil, or naming a path that does not exist → `.created`, at `~/.iris/workspaces/<slug>/`.

**Why creation has exactly one permitted parent.** The model is proposing a path the agent will then write to and run commands in. A denylist of dangerous roots is the obvious guard and the wrong one — denylists leak, and the interesting paths are the ones nobody thought of. Making *creation* structurally impossible outside `~/.iris/workspaces` means a bad proposal can, at worst, name a directory that already exists and is therefore already the user's. It cannot conjure one anywhere.

A missing proposed path is **not an error**. It resolves to a fresh workspace and the panel shows the resolved path before approval, so the fallback is visible rather than silent.

### 4.1 Computed at draft, created at lock

`resolveGoalWorkspace` is **pure and side-effect free**: `.created(path)` names a path, it does not make one. The draft panel calls it to display the resolved workspace, and nothing touches the filesystem until the user approves. A directory is never created for a draft that is edited away or rejected — which matters, because a user may iterate on a contract several times before locking.

At lock the caller re-resolves (the user may have edited the row, which becomes the new `proposed`) and *then* creates the directory for a `.created` result. Re-resolving rather than trusting the displayed value keeps one code path authoritative.

The creating side takes an injected `IrisPaths`, so tests run against a temp root instead of the developer's real `~/.iris` — the same isolation principle as [#121](https://github.com/sackheads/iris/issues/121).

**Slug:** the objective lowercased, non-alphanumerics collapsed to `-`, leading/trailing `-` trimmed, truncated to 40 characters; empty result → `goal`. Collisions append `-2`, `-3`, … until free. Directories are never reused: two goals never share a home, because a stale artifact from an earlier goal is exactly the kind of evidence that makes a grader's verdict wrong.

## 5. A warning, not a block

The draft panel flags a resolved workspace that is:

- the **Iris source tree** (the process cwd) — the literal complaint in #68;
- the user's **home directory**;
- a **dotfile directory** (`~/.ssh`, `~/.config`, …).

It still binds if the user approves. Working on Iris itself is legitimate, and so is a goal that genuinely targets a config directory. What must not happen is it happening *silently*, which is exactly today's behaviour. The warning converts an invisible default into a visible choice.

## 6. Surfacing

- **Draft panel:** an editable workspace row, with the warning from §5 when applicable.
- **Locked panel:** the workspace shown read-only, so the user can see where artifacts are landing mid-run.
- **On lock:** a system message naming the directory.

## 7. Error handling & edge cases

- **Creation fails** (permissions, disk) → the lock proceeds with no binding and a system message saying so. A goal that cannot get a workspace must still be able to run; falling back to today's behaviour is strictly not worse than today.
- **Proposed path is a file, not a directory** → treated as non-existent (rule 3), so it falls back to a fresh workspace.
- **Proposed path contains `~`** → expanded before the existence check, since the model will write it that way.
- **Objective is emoji-only or otherwise slug-empty** → slug is `goal`, collisions handled by §4.
- **Legacy contract** → no `workspace` key, decodes to nil, behaves exactly as before.
- **Amend during a run** → `amend_goal_contract` touches criteria only; the workspace is fixed at lock. Changing where a goal runs mid-flight would invalidate every verdict already recorded against it.

## 8. Interaction constraints (fixed, not a blank slate)

- **Sandboxing is unaffected.** `SandboxPolicy.perWorkspaceOverride` reads an optional per-workspace config file and returns nil when absent, so a freshly created workspace falls through to the global default. Verified rather than assumed — had binding flipped sandbox behaviour, this slice would need a much louder section.
- **`GoalEvaluator` unmodified.** It already resolves the conversation's effective workspace, so the correct directory reaches the grader with no change (slice C's anchoring).
- **D1 unmodified.** The gate does not change; the tree it grades does.
- **`set_workspace` unmodified**, and it still takes precedence.

## 9. Testing

**Pure (no filesystem, no view):**
- `resolveGoalWorkspace` for each rule: existing binding kept; proposed-and-exists bound; proposed-but-missing falls back; nil proposal falls back.
- Slug generation: normal objective, punctuation-heavy, emoji-only, over-long, and collision suffixes.
- The sensitive-path warning fires for the process cwd, home, and a dotfile directory, and does not fire for an ordinary project directory.

**Data safety:**
- `GoalContract` round-trips `workspace`; a pre-#68 contract decodes with it nil and no throw; a `Conversation` carrying such a contract still decodes.

**Handler / integration:**
- Locking a contract with no proposal creates a directory under `~/.iris/workspaces` and binds it (run against a temp root, not the real one).
- Locking with a proposal naming an existing directory binds that directory and creates nothing.
- Locking on a conversation that already has a workspace changes nothing.
- A directory that cannot be created leaves the goal unbound and running, with the system message.

**Regression:**
- A contract-less goal binds nothing.
- A subagent still inherits its parent's workspace.
- `set_workspace` still wins over a proposal.

## 10. What this unblocks

- **D1's gate becomes trustworthy** for `executable` criteria — the headline reason to do this now rather than later.
- **#61 (resume)** gets a stable home to resume into.
- **#13's** inner/outer loop work inherits a real workspace boundary rather than an accident of the process's working directory.

## 11. As-built notes

The design was implemented as written. Two small things worth recording:

- **`JSONValue.stringValue` is non-optional**, so parsing the proposal is `args["workspace"]?.stringValue` followed by a direct `.trimmingCharacters(...)` — not the optional chain the plan showed. Caught at compile time, no behavioural consequence.
- **The draft panel resolves on every keystroke**, which is safe precisely because `GoalWorkspace.resolve` is pure: it stats candidate paths and never creates one. If that function ever grows a write, the panel becomes a directory factory for abandoned drafts — the reason §4.1 exists.

Scope guards for §2 and §7 live in `GoalWorkspaceScopeTests`: a contract-less goal binds nothing, `set_workspace` wins over a proposal, a creation failure leaves the goal running and says so, and a proposal naming a non-existent path never causes that path to appear.
