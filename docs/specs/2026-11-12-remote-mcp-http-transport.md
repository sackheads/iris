---
type: spec
title: Remote MCP servers over Streamable HTTP (#1096)
description: Native Streamable HTTP client transport for MCP servers in mcp_servers.json, plus per-entry decoding so one bad entry no longer hides every server.
tags: [mcp, transport, http, plugins, config]
timestamp: 2026-11-12
---

# Remote MCP servers over Streamable HTTP (#1096)

**Status:** draft for review. Phase 1 only. The Plugins pane revamp is a later, separate piece of work.

## Problem

Iris's MCP client speaks only stdio (`MCPManager.swift`): `MCPServerConfig` is `command`/`args`/`env`,
and every server is a spawned `Process` behind a `StdioTransport`. A remote Streamable HTTP server
such as `https://sharpei.scromp.net/mcp` cannot be configured at all without a stdio-to-HTTP proxy.

Adding sharpei by hand also showed three defects in the loader that are worth fixing on their own:

1. **One bad entry hides every server.** `startServers()` and `configuredServerNames()` decode the
   whole file with a single `try? JSONDecoder().decode([String: MCPServerConfig].self, …)`. An entry
   it cannot model (a remote one, an `mcpServers` wrapper, a stdio entry with no `args`, because
   `args` is not optional) fails the decode, and every server in the file disappears with no status
   and no message.
2. **The `mcpServers` wrapper is refused.** Every other harness writes it, and
   `HarnessConfigImporter` and the snippet wizard accept it.
3. **`removeLegacyServer` (Convert to Plugin) re-encodes the whole file** through the typed map, so
   it would drop any entry it cannot model, and the wrapper, on the way out.

## What already exists

The swift-sdk checkout (`a0ae212`, pinned to `main`, see #1083) ships `HTTPClientTransport`, a
Streamable HTTP client. It handles the following:

- It sends `Accept: application/json, text/event-stream` on every POST. FastMCP answers 406 without
  the event-stream half.
- It handles a JSON response and an SSE response to a POST, and the `Mcp-Session-Id` header if the
  server sets one.
- When `streaming: true`, it opens a background `GET` for server push. A stateless server answers
  `405` to that GET, and the transport cancels only that listener (`HTTPClientTransport.swift:625`).
  The handshake and calls go on over POST.
- It takes a `requestModifier: (URLRequest) -> URLRequest` that runs on every request. Auth headers
  go there.

So this work is mostly config and lifecycle in Iris, not protocol code.

## Design

### Config schema

`mcp_servers.json` stays a map of name to entry, optionally wrapped in `{"mcpServers": {…}}`. An
entry is one of two forms:

```jsonc
{
  "sqlite": {                       // stdio, unchanged
    "command": "uvx",
    "args": ["mcp-server-sqlite", "--db-path", "~/db.sqlite"],
    "env": { "TOKEN": "${keychain:SQLITE_TOKEN}" }
  },
  "sharpei": {                      // remote
    "url": "https://sharpei.scromp.net/mcp",
    "headers": { "Authorization": "Bearer ${keychain:SHARPEI_TOKEN}" }
  }
}
```

Decoding rules (`MCPServerConfig.init(from:)`):

| Field | Rule |
| --- | --- |
| `url` | Canonical remote key. Aliases: `serverUrl` (Antigravity/Windsurf) and `httpUrl` (Gemini CLI). Exactly one of these may appear. More than one is an error, even when they agree, because two keys that disagree have no right answer. |
| `command` | Stdio. An entry with both `command` and a URL key is an error. An entry with neither is an error. |
| `args` | Optional for stdio. Absent means `[]`. Today a missing `args` fails the whole file. |
| `env` | Stdio only. Present on a remote entry is an error, so it doesn't get silently ignored. |
| `headers` | Remote only. `[String: String]`. Present on a stdio entry is an error. |
| `type` | Optional. `http` and `streamable-http` (any case) mean remote, `stdio` means stdio, and either must agree with the keys present. `sse` is refused: "the legacy HTTP+SSE transport is not supported; use the server's Streamable HTTP endpoint". |
| unknown keys | Ignored, as now. Other harnesses add fields such as `disabled` and `timeout`. |

In Swift it is an enum, so no code can touch a stdio field on a remote server:

```swift
enum MCPServerConfig: Codable, Equatable, Sendable {
    case stdio(command: String, args: [String], env: [String: String]?)
    case remote(url: URL, headers: [String: String])
}
```

Encoding writes `command`/`args`/`env` or `url`/`headers`. The canonical keys are the only ones it
emits. The plugin installer emits stdio entries only.

### URL policy

A remote URL must be `https`, or plain `http` to a loopback host (`localhost`, `127.0.0.0/8`, `::1`).
This is checked when the entry starts, not when it is decoded, so the failure shows as a status
(`.failed("…")`) on that one entry. The reason is the bearer token: a plaintext POST sends the token
to whoever is on the path. Loopback is exempt because local development servers rarely have TLS.

### Secrets in headers

Header values expand `${keychain:KEY}` against the `iris.mcp` Keychain service. That is the same
service and the same `PluginReferences.expand` call that `env` already uses (`expandLegacyEnv`).
There is one deliberate difference from `env`:

- **An unresolved reference in a header fails the entry** (`.failed("header Authorization references
  ${keychain:SHARPEI_TOKEN}, which is not in the Keychain")`). It never sends the literal. `env`
  keeps its back-compatible pass-through (`legacyUnresolvable` test), because changing that is out
  of scope and could break a working stdio setup. A header has no such history, and sending
  `Bearer ${keychain:X}` to a remote host leaks the variable name and fails confusingly.

**Populating `iris.mcp`.** Nothing in Iris writes this service today. It is one Keychain item,
account `all-keys`, whose password is a JSON object of key to value. Until the Plugins pane grows a
UI for it (later work) or #966 replaces it, the documented route is:

```sh
security add-generic-password -U -s iris.mcp -a all-keys -w '{"SHARPEI_TOKEN":"…"}'
```

(`iris.mcp.dev` for a dev build.) This overwrites any existing keys in that item, so the docs say to
include them all. macOS asks once whether Iris may read an item the `security` tool created. Literal
header values are still accepted: the file is the user's own, under their home, and refusing them
would only push people back to proxies. The docs recommend the Keychain form.

This is an interim credential path. #966/#974 make credentials registry-owned, so the spec marks
`headers` secrets as a consumer that migrates there, not as the final design.

### Lifecycle

`ActiveServer` stops assuming a process:

```swift
struct ActiveServer {
    let client: Client
    let stop: @Sendable () async -> Void   // stdio: process.terminate(); remote: client.disconnect()
    var availableTools: [MCP.Tool]
    var sanitizedDescriptions: [String: String]
}
```

`stopServers`, `stopServer(named:)` and `stopServers(withPrefix:)` call `stop()`. Stdio behaviour is
unchanged.

Starting a remote server:

1. Validate the URL (policy above) and expand the headers. Either failing means `.failed(reason)`.
2. `HTTPClientTransport(endpoint:, streaming: true, requestModifier:)`, where the modifier sets each
   header with `setValue(_:forHTTPHeaderField:)`. `streaming: true` keeps server push for stateful
   servers. Stateless ones answer 405 and lose nothing.
3. `client.connect(transport:)` and then `listTools()`, under `withTimeout(seconds: 30)`. A stdio
   server that hangs at least has a process; a remote one that never answers would otherwise hold
   `startServers()` forever, and that runs serially at launch (`iris.swift`, after the plugin load).
   On timeout or error, the client is disconnected and the entry becomes `.failed`.
4. The tool descriptions go through `InjectionGuard.sanitize` exactly as for stdio.

Everything downstream (`getGeminiTools`, `callTool`, `readOnlyToolNames`, the outbound gate, profile
`mcp:<name>` matching) sees a remote server's tools identically to a stdio server's.

**A server error between calls.** If the server forgets a session, or the network drops, the next
`callTool` gets an error, which already comes back to the model as `Error calling MCP tool: …`. There
is no automatic reconnect in phase 1. The Plugins pane reload restarts the fleet.

### Per-entry decoding

The legacy file is parsed with `JSONSerialization` into a dictionary (unwrapping `mcpServers`). Each
value is then decoded as its own `MCPServerConfig`. A value that fails is recorded as
`.failed("invalid entry: …")` under its name and does not block its siblings. A file that is not a
JSON object at all (or unreadable JSON) records one status under the reserved name `(config file)`.
It must contain no dot, because the pane lists only dot-free names as legacy servers
(`PluginsSettingsView.legacyServerNames`), and it cannot collide with a real entry name in practice.
A missing file is not an error.

`configuredServerNames()` uses the same parse, so a profile's `mcp:sharpei` is judged against every
named entry, including invalid ones. An invalid entry is a configured server that failed to start, so
it is not "unknown".

`PluginManager.mcpConfigs()` gets the same per-entry treatment. A remote entry inside a plugin's
`mcp.json` is skipped with a printed reason in phase 1, because plugin resolution
(`BinaryResolver`, `${config:}`) and the install wizard are command-shaped. Supporting remote servers
in plugins comes with the pane work.

### `removeLegacyServer`

It edits the parsed raw JSON (dictionary, wrapper preserved), removes the one key, and writes it
back. Entries it cannot model survive untouched. Key order and formatting are not preserved, which
is already true today.

### Status visibility

`serverStatuses()` already feeds the Plugins pane's "Configured in file" list (red/green dot). Phase
1 adds no UI. The failure reason is in `ServerStatus.failed(String)` for the revamp to show. Today
that red dot exists, but the entry never got that far.

## Testing

Test-first, in `MCPManagerConfigTests` / a new `MCPRemoteServerTests`:

- **Decoding:** each alias works; two URL keys fail; `command`+`url` fails; neither fails; missing
  `args` decodes as `[]`; `env` on remote and `headers` on stdio fail; `type: sse` fails with the
  stated reason; `type` that disagrees with the keys fails; unknown keys are ignored; encoding
  round-trips both forms using canonical keys.
- **File parsing:** bare map and wrapper; one bad entry gives one `.failed` and N-1 good ones; a
  non-object file gives one file-level status; `configuredServerNames` includes invalid entries.
- **URL policy:** `https` passes; `http://localhost`, `http://127.0.0.1` and `http://[::1]` pass;
  `http://example.com` fails; a non-http scheme fails.
- **Headers:** a keychain reference expands; an unresolved reference fails the entry with the header
  name in the reason; literals pass through.
- **`removeLegacyServer`:** the wrapper and an unmodellable sibling survive.
- **Loopback integration:** an in-process server on `LoopbackHTTPListener` (port 0) with the SDK's
  `StatelessHTTPServerTransport`, the same pattern as `IrisMCPProviderServer.dispatch`, configured
  to answer like sharpei (JSON responses, 405 on GET). Then `startServers()` → `.running(toolCount:)`,
  a `callTool` round trip, the auth header seen by the server, a wrong token failing as `.failed`,
  and a server that never answers timing out (with an injected short timeout) as `.failed`. Bounded
  with `.timeLimit(.minutes(1))` and `value(of:within:)` per AGENTS.md.

Live check, by hand, not in CI: sharpei through the dev app, listing and calling one tool.

## Docs (invariant 9)

- `docs/features.md` § MCP: wrong today in two ways. It says the file is `~/.iris/mcp_servers.json`
  (it lives under `config/`), and it shows only stdio. Add the remote form, the URL policy, the
  Keychain recipe, and the fact that one bad entry fails alone.
- `HarnessConfigImporter.servers(at:)` doc comment ("remote/HTTP servers are out of scope in v1")
  stays true for the importer, but say it is the importer that skips them, not Iris.
- Grep the agent-facing strings for `mcp_servers` and `command` claims.

## Out of scope

OAuth and discovery (a 401 or 403 is a clear `.failed`); automatic reconnect; the legacy HTTP+SSE
dual-endpoint transport; remote entries in plugins and the import wizard; the Plugins pane revamp; a
Keychain editing UI; moving the SDK pin (#1083), though this work is a reason to do it.

## Risks

- **SDK on `main`.** `HTTPClientTransport`'s initializer could change under us before #1083 pins a
  tag. The integration test catches that.
- **`streaming: true` against a stateless server** depends on the 405 path (verified in source, not
  yet against a live FastMCP). The integration test simulates it, and the live check confirms it.
- **Launch latency.** Remote connects run serially in `startServers()`. One slow server delays
  later ones by up to the timeout. Running them concurrently is a separate change, not this one.
