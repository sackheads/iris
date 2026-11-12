# MCP provider (Iris as an MCP server)

The reverse direction from the [MCP client](features.md#model-context-protocol-mcp): instead of
Iris loading external tool servers, a developer's own MCP client (Claude Code, another editor
integration, a script) can talk *to* Iris over a small, local, token-gated surface. Off by
default. This is Phase 1 (#1067) — a plain client↔Iris channel, not client-to-client relay and not
the role-session turn machinery Phase 2 will add on top of it.

## What it is

A loopback-only HTTP listener speaking the [Model Context Protocol](https://modelcontextprotocol.io/)
wire format, built fresh per request: every request gets its own `MCP.Server` and transport pair,
authenticated and admitted before either exists. Nothing here touches `Conversation.history`,
the peer-cascade budget, or the taint model — it is a standalone surface with its own storage.

## Enabling it

Off by default (`GuardedKey.mcpProviderEnabled`). Turning it on binds a loopback listener at
launch, on `mcpProviderPort` (a dev build and the release build default to different ports, so
both can run at once on one machine). Toggling the setting takes effect on the next launch, not
immediately.

Each client authenticates with a per-token-registry bearer token (`ProviderTokenRegistry`). As of
this Phase 1 build, nothing wires this setting or a token into anything a person can actually use:
there is no Settings toggle for `mcpProviderEnabled`/`mcpProviderPort`, and no UI or command issues
a token. The provider's code is complete and tested, but dormant end to end until that wiring
lands — tracked separately, not an oversight here.

## The Phase 1 surface

Six read-only self-report tools (window owner, responder class, composer state, turn state,
activation state, a diagnostic event ring), each a bounded field — a bool, a count, a bundle
identifier, a class name — never a window title, transcript text, memory, or file content. The
window-owner tool specifically discloses the *frontmost* app's bundle identifier, which is not
always Iris — a client asking it learns what else has the user's focus, not only facts about Iris.

And a messaging/file-exchange surface addressed to Iris itself — `iris_send`/`iris_poll`/
`iris_discover`/`iris_status`/`artifact_put`, no recipient argument, no tool or method here lets
one registered client reach another. In this build the surface only stores: `iris_send` writes a
message into the mailbox (capped at 500 pending per sender, 16 KiB of text and 8 file references
per message, swept after a 7-day TTL) and `artifact_put` stores bytes in a content-addressed store
(8 MiB per object, 200 MiB per client per day, a 2 GiB total cap, also swept after 7 days) — but
nothing on the Iris side drains a sent message or calls `deliverReply`, so `iris_poll`/`iris_status`
are always empty and a client never receives a reply. The round trip (Iris actually reading and
answering) is Phase 2's work, on top of this storage.

## Security posture

- **Default-deny dispatch.** Every JSON-RPC method is checked against an explicit allowlist before
  any `MCP.Server` exists; an unlisted method is refused. An id-less notification not on the
  allowlist is accepted and silently dropped (per the MCP spec, a notification gets no response
  either way), not refused — only a request (one with an `id`) gets an error back.
- **Auth before anything else.** A bearer token resolves to a client id before the request body is
  even parsed; a missing, malformed, or unknown token gets a flat 401.
- **Separately budgeted, and only rate — not concurrency.** The self-report door and the
  messaging/file tools each have their own token-bucket budget on requests per minute; neither
  gate caps how many requests from one client run at once. The one concurrency cap in this surface
  is the loopback listener's own connection limit (16 at a time, shared by every client).
- **Fail-closed storage.** The mailbox and the content-addressed artifact store are their own
  actors, entirely separate from the conversation-scoped attachment exchange; a read requires the
  requester to already be in that object's authorized-reader set — a correct hash alone never
  grants access.

See [docs/superpowers/plans/2026-11-11-mcp-provider-phase1.md](superpowers/plans/2026-11-11-mcp-provider-phase1.md)
for the full design history and the invariants this surface is built against.
