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

Each client authenticates with a per-token-registry bearer token (`ProviderTokenRegistry`); Phase
1 ships no UI to issue or revoke one — that is a deliberate onboarding gap for a later phase, not
an oversight.

## The Phase 1 surface

Six read-only self-report tools (window owner, responder class, composer state, turn state,
activation state, a diagnostic event ring), each a bounded field — a bool, a count, a bundle
identifier, a class name — never a window title, transcript text, memory, or file content. And a
plain messaging/file-exchange surface: `iris_send`/`iris_poll`/`iris_discover`/`iris_status` and
`artifact_put`, all addressed to Iris itself — there is no recipient argument, and no tool or
method on this surface lets one registered client reach another.

## Security posture

- **Default-deny dispatch.** Every JSON-RPC method is checked against an explicit allowlist before
  any `MCP.Server` exists; an unlisted method is refused, never silently passed through.
- **Auth before anything else.** A bearer token resolves to a client id before the request body is
  even parsed; a missing, malformed, or unknown token gets a flat 401.
- **Rate/concurrency budgeted separately per surface.** The self-report door and the
  messaging/file tools each have their own token-bucket budget, charged once per request.
- **Fail-closed storage.** The mailbox and the content-addressed artifact store are their own
  actors, entirely separate from the conversation-scoped attachment exchange; a read requires the
  requester to already be in that object's authorized-reader set — a correct hash alone never
  grants access.

See [docs/superpowers/plans/2026-11-11-mcp-provider-phase1.md](superpowers/plans/2026-11-11-mcp-provider-phase1.md)
for the full design history and the invariants this surface is built against.
