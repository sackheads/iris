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

## 4. The sidebar

`ChatView`'s sidebar gains a second section:

- **Conversations** — `conversations.filter { !$0.isSubagent && !$0.isArchived }` (the existing
  filter gains one clause).
- **Archived** — `conversations.filter { !$0.isSubagent && $0.isArchived }`, in a `DisclosureGroup`
  collapsed by default. Omitted entirely when empty, so a user who never archives sees no change.

Collapse state is view `@State`, not a persisted preference. Decluttering works per-launch, and
this avoids adding a setting for something the user re-expresses by clicking.

## 5. Selection: the hazard this design dissolves

Three paths can set `selectedConversationId`, and each has historically been able to point it at a
conversation the sidebar does not render — a class of bug this repo has fixed before (#167) and
guarded against since (#212's `reveal` miss-guard):

- `deleteConversation`'s re-point, currently `conversations.last(where: { !$0.isSubagent })`
- `deleteConversation`'s "nothing left, make one" check
- `reveal(hit:)` from search

**Keeping archived conversations in the same list removes the class rather than guarding it three
more times.** An archived conversation is still rendered — in a collapsed section — so selecting it
by any path shows the user something. `reveal(hit:)` needs no archive awareness, and search needs
no change at all.

One refinement, not a fix: `deleteConversation`'s re-point should **prefer** an active conversation
and fall back to an archived one, so deleting the last active conversation does not silently drop
the user into the archive.

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

**Selection in that case moves to the new conversation**, which is the one exception to §5's
"selection is untouched". The general rule holds because an archived conversation stays rendered
and therefore stays a valid selection; but when archiving created a replacement precisely because
the user had nowhere to type, leaving them selected on the thing they just filed away would defeat
the reason the replacement exists. Selection moves only when a conversation was created — archiving
one of several active conversations leaves selection alone.

## 9. Search

Archived conversations remain indexed and searchable, unchanged. A hit reveals and selects normally
(§5). No special casing, no mode switch, no "expand the archive to show you this" behaviour —
because the conversation was never unreachable.

## 10. Testing

- **Store round-trip through `ConversationStore`**, not the JSON codec: `isArchived` survives a real
  load. A JSON-only test would pass while the field is never persisted (§3).
- A conversation with no `isArchived` key decodes as active (invariant 1).
- Archiving is refused with a turn in flight, and refused with an active goal — each asserted
  separately, since they are independent conditions.
- Archiving the selected conversation, when other active conversations exist, leaves it selected
  and still rendered in the Archived section.
- Archiving the last active conversation yields a new active conversation **and** moves selection
  to it — the §8 exception, asserted rather than inferred from the two rules it sits between.
- `/unarchive` returns it to the active section.
- A search hit on an archived conversation still reveals and selects it.
- `deleteConversation` prefers an active conversation when re-pointing selection, and falls back to
  an archived one rather than to nothing.
