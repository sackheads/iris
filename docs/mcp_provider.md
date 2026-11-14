# MCP provider (Iris as an MCP server)

The reverse direction from the [MCP client](features.md#model-context-protocol-mcp): instead of
Iris loading external tool servers, a developer's own MCP client (Claude Code, another editor
integration, a script) can talk *to* Iris over a small, local, token-gated surface. Off by
default. Phase 1 (#1067) is a plain client↔Iris channel, never client-to-client relay; Phase 2
(#1066) adds, behind a second off-by-default setting, [guest sessions](#guest-sessions): a confined
model turn that answers each client's messages.

## What it is

A loopback-only HTTP listener speaking the [Model Context Protocol](https://modelcontextprotocol.io/)
wire format, built fresh per request: every request gets its own `MCP.Server` and transport pair,
authenticated and admitted before either exists. The self-report door and the mailbox are a
standalone surface with their own storage: they never touch `Conversation.history`, the
peer-cascade budget, or the taint model. A guest session (below) is the one part that does: it is a
hidden, never-persisted `Conversation` whose messages count toward the peer-cascade depth.

## Enabling it

Off by default (`GuardedKey.mcpProviderEnabled`). Turning it on binds a loopback listener at
launch, on `mcpProviderPort` (a dev build and the release build default to different ports, so
both can run at once on one machine). Toggling the setting takes effect on the next launch, not
immediately.

Each client authenticates with a per-token-registry bearer token (`ProviderTokenRegistry`). As of
this build, nothing wires this setting or a token into anything a person can actually use: there is
no Settings toggle for `mcpProviderEnabled`, `mcpProviderPort` or `mcpGuestSessionsEnabled`, and no
UI or command issues a token or sets a client's role allowlist. The provider's code is complete and
tested, but dormant end to end until that wiring lands — tracked separately, not an oversight here.

## The messaging surface

Six read-only self-report tools (window owner, responder class, composer state, turn state,
activation state, a diagnostic event ring), each a bounded field — a bool, a count, a bundle
identifier, a class name — never a window title, transcript text, memory, or file content. The
window-owner tool specifically discloses the *frontmost* app's bundle identifier, which is not
always Iris — a client asking it learns what else has the user's focus, not only facts about Iris.

And a messaging/file-exchange surface addressed to Iris itself — `iris_send`/`iris_poll`/
`iris_discover`/`iris_status`/`artifact_put`, no recipient argument, no tool or method here lets
one registered client reach another. By default the surface only stores: `iris_send` writes a
message into the mailbox (capped at 500 pending per sender, 16 KiB of text and 8 file references
per message, swept after a 7-day TTL) and `artifact_put` stores bytes in a content-addressed store
(8 MiB per object, 200 MiB per client per day, a 2 GiB total cap, also swept after 7 days), and
nothing on the Iris side drains a sent message, so `iris_poll`/`iris_status` stay empty and a client
never receives a reply. Turning on the guarded `MCP_GUEST_SESSIONS_ENABLED` setting (off by default,
no Settings toggle yet, a `"true"` written from outside the app does not count, #678) changes that:
`iris_send` also starts one model turn in that client's own guest session, on the cheapest model
tier with the two-tool guest floor, and the final answer comes back through `iris_poll`. Only the message text reaches that session: file references are stored and granted as before, but are not shown to it. A client
gets at most 12 such turns an hour (one more every 5 minutes), one turn at a time, and a turn that
cannot start (every guest slot taken, or the hourly limit) is a tool error, not a queued message.
A turn that fails or runs out of time is answered with a short failure message rather than silence.

## Security posture

- **Default-deny dispatch.** Every JSON-RPC method is checked against an explicit allowlist before
  any `MCP.Server` exists; an unlisted method is refused. An id-less notification not on the
  allowlist is accepted and silently dropped (per the MCP spec, a notification gets no response
  either way), not refused — only a request (one with an `id`) gets an error back.
- **Auth before anything else.** A bearer token resolves to a client id before the request body is
  even parsed; a missing, malformed, or unknown token gets a flat 401.
- **Separately budgeted, and only rate — not concurrency.** The self-report door and the
  messaging/file tools each have their own token-bucket budget on requests per minute, and guest
  turns have a third (12 an hour per client); none of these gates caps how many requests from one
  client run at once (a guest session does run one turn at a time per client). The one concurrency cap in this surface
  is the loopback listener's own connection limit (16 at a time, shared by every client).
- **Fail-closed storage.** The mailbox and the content-addressed artifact store are their own
  actors, entirely separate from the conversation-scoped attachment exchange; a read requires the
  requester to already be in that object's authorized-reader set — a correct hash alone never
  grants access.

## Guest sessions

*(#1066, Phase 2.)* With `MCP_GUEST_SESSIONS_ENABLED` on, an `iris_send` starts a turn in a **guest
session** and the answer comes back through `iris_poll`. The reply direction above is the whole of
it: a guest never gets an address a role session could message first.

- **What a guest is.** One hidden conversation per client id (not per MCP session), with its own
  engine under the `mcpGuest` principal. It is never persisted (a restart starts with none), never
  listed by `list_sessions`, and its prompt is the guest prompt alone: no `SOUL.md`, `USER.md`,
  workspace `AGENTS.md`, skills, facts or memory. It runs on the cheapest model tier.
- **The two-tool floor.** A guest declares and can call exactly `list_sessions` and `send_to_session`.
  Every other tool, and any argument those two do not take (no `attachments`, no `to` other than a
  role), is refused at dispatch. Its YOLO mode is never on, and a role session's turn that a guest
  message started or steered asks for approvals as usual for that turn (#1119).
- **The per-client role allowlist.** A guest reaches only the roles its client was granted
  (`ProviderTokenRegistry.setRoles`). The default is empty: a guest with no role can message
  nobody. It cannot name `iris`, a session id, a name, a topic or another guest. A role session
  answers a guest only with `in_reply_to` (the guest is hidden and has no address); once the guest
  session is closed or reaped, that reply is refused as "no longer active".
- **What a role session sees.** A guest's message arrives framed as a request from an external MCP
  guest, naming the client id the harness stamped (never text the guest wrote), marked as not from
  the user and not from the system. It starts at hop depth 1 and each ping-pong round adds one, up
  to the usual `maxSessionCascade`.
- **Cost.** Guest traffic **spends the owner's tokens**: the guest's own turn and every turn it
  causes in a role session. The bounds are per turn and per client rate, not a budget: one live
  session per client, at most 4 live at once (a fifth client gets a busy error, nothing is queued),
  a session closed after 15 idle minutes (a turn in flight is never reaped; the clock restarts when
  it ends), 12 turns an hour per client (one more every 5 minutes), one turn at a time per client,
  and a per-turn ceiling of 30,000 weighted tokens and 180 seconds
  (`GuestSessionDriver`'s named constants). A turn that fails or times out is answered with a short
  failure message. There is **no per-client daily or total spend cap yet**: that is tracked in
  #1135 and should land before this setting is turned on for anyone. `GuestSpendLedger` tallies
  each client's tokens in memory so the spend is at least visible; it enforces nothing and does not
  survive a restart.
- **The flag.** `MCP_GUEST_SESSIONS_ENABLED` is a guarded setting, off by default (off is its
  protective value): a `"true"` written from outside the app is not carried across an upgrade and
  an unreadable settings item loads it off. Off, `iris_send` is exactly the mailbox above. It is read
  on every `iris_send`.
- **Revoking and stopping.** Revoking a client closes its session even if the token revoke fails
  and clears its turns bucket, so a re-issued id starts fresh. An idle reap deliberately keeps the
  bucket: clearing it there would let a client reset its hourly limit by waiting out the TTL.
  Stopping the provider closes every live guest session. A reply is never filed for a client that
  was revoked while its turn ran.
- **Dormant for now.** Nothing issues a token or sets a role allowlist from the app, and there is
  no Settings toggle for the flag, so this is code and tests until that wiring and #1135 land.

See [docs/superpowers/plans/2026-11-11-mcp-provider-phase1.md](superpowers/plans/2026-11-11-mcp-provider-phase1.md)
for the full design history and the invariants this surface is built against.
