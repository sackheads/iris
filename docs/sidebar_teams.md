# Sidebar Teams

A team is a persistent, named group of conversations in the sidebar (#960) — not a visual
folder that empties out on its own, but a standing group you create once and keep until you
explicitly retire or delete it. The sidebar is otherwise unchanged: pinned conversations stay
at the top, un-pinned and ungrouped conversations stay in the flat "Conversations" list, and
Archived stays a collapsed `DisclosureGroup` at the bottom. Teams sit between the flat list and
Archived, each its own collapsible `DisclosureGroup`.

## Creating and managing a team

The folder-plus button beside **New Conversation** opens a "New Team" prompt (name only). A
team's `+` (in its own disclosure label) starts a new conversation already in that team. Right-
click, or the context menu on a team's label, offers **Rename Team…** and **Delete Team**.
Deleting a team ungroups every member back to the flat list — it never archives or deletes a
conversation, and the confirmation says so.

## Reordering and moving

Drag a conversation between the flat list and a team, or between two teams, to move it; drag
within a list to reorder. Teams themselves are also drag-reorderable, independently of their
members. A pinned conversation cannot be grouped (pinned conversations stay pinned at the top
regardless of team membership). An empty team persists exactly like one with members — a team
with no members right now is not the same as a team that doesn't exist.

## Idle auto-archive exemption

A team's member never ages out of the 14-day idle auto-archive sweep ([Sessions](sessions.md))
for as long as it stays grouped — a team is a standing assignment, not a schedule, and the sweep
must never be the thing that moves a member out of a team on its own. The exemption lifts the
moment a member leaves its team, whether by dragging it out, by deleting the team (which
ungroups every member), or by archiving it directly (archiving — "retiring" a member — is the
same action as always; it is unaffected by team membership and leaves the team itself in place
for its other members).

## Persistence

A team (its id, name and sort position) is stored independently of its members, so renaming or
reordering it needs no member present, and archiving or deleting a member never loses the
team's own name. Membership is one field on the conversation itself; a conversation decoded
before #960 has no team, the same as any other field this old.
