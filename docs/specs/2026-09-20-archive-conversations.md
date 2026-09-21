# Archive Conversations — Design

**Status:** approved, not yet implemented
**Issue:** #182

## 1. Overview

A conversation can be archived: it leaves the main sidebar list and moves to a collapsed
**Archived** section below it. Archiving is reversible, changes nothing about the conversation's
content, and keeps it searchable. The goal is decluttering the active list without deleting
anything worth keeping.

**Archiving is a list-management gesture, not a control gesture.** It must never change what the
agent is doing, and it must never move a conversation somewhere the user cannot reach. Both
constraints drive the design below more than the feature itself does.

**The unifying rule: archived means idle.** It has two directions, and every behaviour below is one
of them:

- A conversation **doing work cannot be archived** (§6.1).
- A conversation that **receives work becomes active again** (§6.2) — typing into it, a scheduled
  job firing into it, or a subagent posting back to it.

Without the second direction, archiving is only a gate on one gesture: `sendMessage` routes by
`selectedConversationId` with no archive check, and a `ScheduledJob` carries a `conversationId` it
fires a prompt into. Either would start a turn inside a collapsed section — the exact outcome §6.1
exists to prevent.

## 2. Scope

In: the flag and its persistence, the sidebar section, `/archive` and `/unarchive`, the context-menu
items, and the refusal when work is in flight.

Out, deliberately — neither is in the issue and both are additive later: bulk operations
(archive-all, multi-select, sorting the archive) and auto-archiving by age or inactivity.

## 3. State

`Conversation.isArchived: Bool = false`.

Persisting it takes **two** changes, and doing only the first is the mistake slice D3 shipped:

1. `decodeIfPresent(Bool.self, forKey: .isArchived) ?? false` in `Conversation.init(from:)`, plus
   its `CodingKeys` case (invariant 1 — a synthesized decoder throws on a missing key and drops
   every conversation).
2. A real `isArchived` column in `ConversationStore`: a `v6` migration, both `upsertMetadata`
   branches, and `loadAll`. **Post-#197 the JSON codec is not the metadata persistence path** —
   the store enumerates its columns by hand, so a field absent from them is silently dropped on
   every load while its JSON round-trip test passes. `ConversationStoreTests.roundTrip` ("every
   stored field") is the test that proves persistence and must cover it.

**`isSubagent` is not a precedent here.** It has no column because subagent conversations are
filtered out of persistence entirely (`durableConversations`). Archived conversations must persist,
so the flag needs real storage.

Default `false` means every existing conversation loads as active, which is the desired migration.

An unreadable or garbled `isArchived` value defaults to `false` (active) and warns, matching the
store's existing treatment of a corrupted integer column (#189). A conversation must never become
unreachable because its flag did not parse — the failure direction is toward visibility.

**Migration number:** name it by purpose (`v7_archive`) and assign the number against `main` at
implementation time. `v6` is taken by the open checkpoint-judgement branch (#191), and whichever
merges second has to renumber.

## 4. The sidebar

`ChatView`'s sidebar gains a second section:

- **Conversations** — `conversations.filter { !$0.isSubagent && !$0.isArchived }` (the existing
  filter gains one clause).
- **Archived** — `conversations.filter { !$0.isSubagent && $0.isArchived }`, in a `DisclosureGroup`
  collapsed by default. Omitted entirely when empty, so a user who never archives sees no change.

Collapse state is view `@State`, not a persisted preference. Decluttering works per-launch, and
this avoids adding a setting for something the user re-expresses by clicking.

## 5. Selection: three paths dissolved, one ruled

Four paths set `selectedConversationId`, and each has historically been able to point it at a
conversation the sidebar does not render — a class of bug this repo has fixed before (#167) and
guarded against since (#212's `reveal` miss-guard):

- `deleteConversation`'s re-point, currently `conversations.last(where: { !$0.isSubagent })`
- `deleteConversation`'s "nothing left, make one" check
- `reveal(hit:)` from search
- **`loadConversations` at launch**: `selectedConversationId = loaded.last?.id`, ordered by
  `position`, which is assigned at INSERT and never changed

(`createNewConversation` assigns it too, always to a conversation it just made active — harmless.)

**The launch path needs an explicit rule, and it is the one case the same-list design does not
dissolve on its own.** `position` does not change when a conversation is archived, so archiving
your newest conversation would make every subsequent launch open onto it, inside the collapsed
section, with every launch notice appended there.

Launch selection therefore **prefers the last non-archived conversation**, falling back to an
archived one only when no active conversation exists at all. Launch notices target whatever is
selected, so in that fallback they land in the archived conversation — acceptable because it is the
only conversation there is, and §6.2 un-archives it the moment anything is sent.

**Keeping archived conversations in the same list removes the class for three of these.** An
archived conversation is still rendered — in a collapsed section — so a delete re-point or a search
reveal shows the user something. `reveal(hit:)` needs no archive awareness and search needs no
change at all.

It does **not** remove it for the launch path, because that one picks by `position` rather than by
what the user last touched. That case gets an explicit rule below rather than a claim that it
cannot happen.

**Delete, stated in full** — the earlier draft left this contradictory. `deleteConversation`:

- re-points selection to the last **active** conversation, and
- its "nothing left, make one" check counts **active** conversations only
  (`!$0.isSubagent && !$0.isArchived`), so deleting your last active conversation creates a fresh
  one and selects it.

There is deliberately **no** fallback to an archived conversation: the creation check would
immediately supersede it, so that branch could never be reached. Deleting your last active
conversation puts you in a new empty one, not in the archive — the same answer §8 gives for
archiving your last active conversation, for the same reason.

## 6. Archiving

Two entry points, one behaviour:

- `/archive` — archives the current conversation.
- A sidebar context-menu item on any conversation.

### 6.1 Refused while work is in flight

Archiving is **refused** when either holds for the target conversation:

- `hasTurnInFlight(for:)` is true, or
- `activeGoal != nil`.

The refusal names the reason and the remedy (`/stop`). This is the constraint from §1: archiving
must not quietly stop an agent, and allowing it to proceed would leave an autonomous goal loop
running inside a section that is collapsed by default — work happening where nobody is looking,
which is the failure shape this codebase keeps having to dig out of.

The cost is one extra step in exactly the case where the extra step is the point.

### 6.2 Work arriving un-archives

The second direction of §1's rule. **Two choke points clear `isArchived` on their target
conversation**, stated here rather than enumerated per caller:

1. **`IrisEngine.handleSystemEvent(_:source:conversationId:)`** — every non-user arrival goes
   through it: the scheduler, background subagent post-backs, and the file watcher. It resolves its
   target as `conversationId ?? selectedConversationId`, so naming the rule here covers all three
   and cannot go stale when a fourth is added.
2. **`AppState.runThinkingTask(conversationId:)`** — every user-initiated turn is started through
   it, so it covers the ordinary send, the four slash commands that start a drafting turn and
   return before `sendMessage`'s tail (`/goal`, `/reflect`, `/vibecop init`, `/rename`), the
   goal-contract kickoff, and every goal-loop resume. Scoped deliberately: slash commands that
   start no turn never reach it, so `/tokens` un-archives nothing.

Enumerating arrival routes is the wrong shape for this rule. The watcher already proves it: it
calls `handleSystemEvent` with **no** conversation id, so it targets whatever is selected — and §8
deliberately leaves the user selected on a conversation they just archived. A per-caller rule would
have missed it.

**Why un-archive rather than refuse.** For the composer, refusing leaves a pane the user can read
but not use, with no obvious way out; un-archiving is what they meant by typing into it. For an
arrival, skipping the work would make archiving silently cancel a scheduled job or discard a
subagent's result — the control-gesture behaviour §1 forbids.

**Notices differ by direction, because the user's attention does:**

- **Typing** needs no notice. The user is looking at the thing that moved.
- **An arrival** happens with the user elsewhere: a row silently reappears, and if it was the last
  archived conversation the whole section vanishes. `handleSystemEvent` already appends a system
  line for the event; that line names the un-archive ("un-archived: scheduled job"). **Selection
  does not move** — the conversation resurfacing is not a reason to yank the user out of what they
  are reading.

## 7. Restoring

`/unarchive` and a context-menu item clear the flag; the conversation moves back to
**Conversations**. Selection is untouched, because it was valid in either section.

## 8. The last-active conversation

`deleteConversation` already creates a fresh conversation when no durable one remains. Archiving
needs the same guarantee for a different reason: archiving your only active conversation leaves
nowhere to type.

**Archiving ensures at least one active conversation exists**, creating an empty one if the action
would leave none. §6.1's refusal is what makes this safe — the newly created conversation can never
inherit a running goal, because a conversation with one cannot be archived in the first place.

**Selection in that case moves to the new conversation**, which is the one exception to §7's
"selection is untouched". The general rule holds because an archived conversation stays rendered
and therefore stays a valid selection; but when archiving created a replacement precisely because
the user had nowhere to type, leaving them selected on the thing they just filed away would defeat
the reason the replacement exists. Selection moves only when a conversation was created — archiving
one of several active conversations leaves selection alone.

## 9. Search

Archived conversations remain indexed and searchable, unchanged: `searchConversations` joins
`conversations` only for the title, so no filter is involved.

**While a query is active, neither section renders.** #212 replaces the whole Conversations section
with Results, so an archived hit is just a row like any other. Results are grouped by conversation
(a header plus its per-message hits), so the muted "Archived" marker belongs on the **group
header**, not repeated on every hit row — the user needs to know where clicking will take them.

**After the query clears**, the revealed conversation is selected but, if archived, sits inside a
collapsed group — a selected row the user cannot see, which is the residue of the hazard §5
dissolves. So: **the Archived disclosure group auto-expands when the selected conversation
*becomes* archived** — either because the selection moved onto an archived row, or because the
conversation the user is already on was archived where it stands (§6's `/archive` and context
menu, which move no selection at all). That is the whole of the "expand to show you this"
behaviour — driven by selection and archive state, not by search, so it covers the launch fallback
(§5) and a delete re-point equally.

It is an **auto-expand, not a pin**: the disclosure triangle is a plain binding, and neither
opening nor closing it changes the selection or archives anything, so an explicit collapse holds
until the next time the selected conversation becomes archived. Archiving some *other*
conversation, or un-archiving the selected one, is not such an event and leaves the group as the
user left it. Pinning it open instead would make the triangle visibly inert while an archived row
stayed selected.

### 9.1 Ordering and the context menu

**Ordering.** Archived rows keep their `position`, which is assigned at INSERT and never changed,
so the Archived section preserves original list order rather than archive date. Acceptable for a
decluttering feature; sorting the archive is out of scope (§2).

**Context menu.** The existing menu lives in the Conversations section. Archived rows get the same
menu with **Unarchive** substituted for **Archive**; Export and Delete remain available in both.

**Where a refusal is shown (§6.1).** `/archive` appends a system line to the conversation. A
context-menu click has no such channel, so the menu item is **disabled** there, with its title
carrying the reason ("Archive (goal running)") rather than failing silently on click. The title is
computed when the menu is built and a turn can start before the click lands, so the action
re-checks; when that late refusal fires it is written **into the conversation the user is looking
at** (naming the refused conversation), as well as into the refused conversation's own transcript
— the right-clicked row is usually not the one on screen.

## 10. Documentation

Invariant 9 applies: this changes user-facing behaviour, so it must fix what it makes untrue, not
only describe what it adds.

- **`README.md`** — the sidebar and search descriptions (`:18`, `:31`, `:118`) and the context-menu
  list (`:40`) describe a single conversation list. Each needs the archive section, and the search
  bullet needs "archived conversations stay searchable".
- **`README.md:119`** ("Session Control") — `/archive` and `/unarchive` belong beside `/new` and
  `/clear`.
- **`docs/slash_commands.md`** and **`SlashCommandItem.allCommands`** — add `/archive` and
  `/unarchive`. The latter drives the in-app autocomplete, so omitting it makes the commands
  undiscoverable even though they work.

## 11. Testing

- **Store round-trip through `ConversationStore`**, not the JSON codec: `isArchived` survives a real
  load. A JSON-only test would pass while the field is never persisted (§3).
- A conversation with no `isArchived` key decodes as active (invariant 1).
- A garbled `isArchived` value loads the conversation as active rather than failing it (§3).
- Archiving is refused with a turn in flight, and refused with an active goal — each asserted
  separately, since they are independent conditions.
- Archiving the selected conversation, when other active conversations exist, leaves it selected
  and still rendered in the Archived section.
- Archiving the last active conversation yields a new active conversation **and** moves selection
  to it — the §8 exception, asserted rather than inferred from the two rules it sits between.
- **`sendMessage` into an archived conversation un-archives it before the turn starts** (§6.2).
- **`/goal` into an archived conversation un-archives it** (§6.2) — it starts a real drafting turn
  and returns above `sendMessage`'s tail, so it is the case a per-command rule loses.
- **The goal-contract kickoff un-archives its conversation** (§6.2) — `GoalContractPanel` calls
  `sendGoalKickoff` directly, reaching `sendMessage` not at all.
- **A scheduled job firing into an archived conversation un-archives it** (§6.2).
- **A background subagent posting back to an archived conversation un-archives it** (§6.2) — the
  same choke point, asserted separately because it is a different caller with a different target
  (it passes an explicit id, where the watcher passes none).
- **An arrival un-archive does not move selection**, and its system line names the un-archive
  (§6.2).
- **The Archived group auto-expands when the selected conversation becomes archived** (§9) — the
  one genuinely new UI rule, and the thing that keeps a selected row from being invisible after a
  search reveal or the launch fallback. Both triggers asserted: the selection moving onto an
  archived row, and the selected conversation being archived in place. Plus the other side of the
  same rule — an explicit collapse survives the selection staying put, another conversation being
  archived, and the selected one being un-archived.
- **Launch selection prefers the last non-archived conversation**, and falls back to an archived one
  only when no active conversation exists (§5). Both halves asserted — the fallback is what makes
  the preference meaningful.
- `deleteConversation` re-points to the last **active** conversation, and creates a new one when no
  active conversation remains (§5) — both halves, since they are the contradiction the earlier draft
  left open.
- `/unarchive` returns a conversation to the active section.
- A search hit on an archived conversation still reveals and selects it.
- Docs updated (§10) — checked by review, not by a test.
