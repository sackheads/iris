---
type: spec
title: MCP & Plugins Pane Revamp and Remote Plugin Support (#1105)
description: Unified MCP & Plugins settings UI with native Remote HTTP / Local Command add forms, remote servers in plugins, inline Keychain secret editing, and a live tool inspector.
tags: [mcp, plugins, ui, keychain, http]
timestamp: 2026-11-13
---

# MCP & Plugins Pane Revamp and Remote Plugin Support (#1105)

**Status:** implementation spec. Follows #1096 / #1101 (Streamable HTTP client transport).

## Problem

#1101 added Streamable HTTP support to `MCPManager`, but the Plugins settings pane and plugin pipeline still block the actual workflow:

1. **Plugins only support stdio.** `PluginManager.mcpConfigs()`, `PluginInstaller.draft(fromSnippet:)`, `PluginInstaller.regenerate(_:)`, and `HarnessConfigImporter.servers(at:)` all require a `command` string and skip or reject remote (`url` / `serverUrl` / `httpUrl`) servers. That forces remote servers into hand-edited `mcp_servers.json` + Terminal `security add-generic-password` commands.
2. **Two-tier sidebar with unselectable file entries.** `PluginsSettingsView` splits the list into "Plugins" and "Configured in file", does not make "Configured in file" rows selectable, and offers an `Edit mcp_servers.json` link that opens an external editor on `{}`. When a file-configured server fails to start, its `.failed(reason)` status is invisible.
3. **Dead empty state and no direct form for adding a server.** Opening the pane shows *"Select a plugin"* on the right. Adding a server requires choosing between three modal wizard flows ("From Folder", "From MCP Snippet", "Import from Another Harness"), none of which lets the user type a URL and Bearer token (or a command and args) directly.
4. **Secret-saving footgun and no tool visibility.** In `PluginDetailView`, `SecureField` only saves on `.onSubmit` (Return key) with no Save button, there is no Reconnect button, and there is no inspector showing which tools a server registered or whether they are `readOnlyHint: true`.

## Design

### 1. Remote servers in `PluginManager`, `PluginInstaller`, and `HarnessConfigImporter`

- **`PluginManager`:**
  - `mcpConfigs()` resolves both `.stdio` and `.remote` entries in a plugin's `mcp.json`.
  - For `.remote(url, rawHeaders, allowedKeys)`:
    - Every `${keychain:KEY}` reference in `rawHeaders` must be present in `allowedKeys` (in addition to `evaluateReadiness` checking that every `${keychain:KEY}` in `mcp.json` is declared in `manifest.secrets` and present in the plugin's `iris.plugin.<id>` Keychain item). If a header references a key outside `allowedKeys`, `resolveServer` refuses the server.
    - Header values expand `${keychain:KEY}` and `${config:KEY}` in memory against the plugin's `secrets` (`iris.plugin.<id>`) and effective `configValues`. The resolved `.remote(url: url, headers: expanded, allowedKeys: allowedKeys)` is passed to `MCPManager`.
- **`PluginInstaller`:**
  - `draft(fromSnippet:)` accepts both stdio (`command`) and remote (`url` / `serverUrl` / `httpUrl`) server objects.
  - **Header classification (`classifyHeaders`):**
    - If a header value already contains `${keychain:KEY}` or `${config:KEY}` references (e.g. when upgrading an existing `mcp_servers.json` entry), the template is preserved and the referenced keys are declared in the manifest.
    - If a header value has a `"Bearer "` prefix (case-insensitive) followed by a literal token, the `"Bearer "` prefix stays in the `mcp.json` header template (`"Bearer ${keychain:<KEY>}"`) and only the raw token is lifted into `secretValues[<KEY>]`. That way the `SecureField` in Settings holds the raw token rather than requiring the user to type `Bearer ` into a password field.
    - Any other header on a remote snippet whose name is `"Authorization"` or matches `isSecretLooking(key:)` lifts its value into `${keychain:<KEY>}` and adds `<KEY>` to `allowedKeys`; non-secret headers lift into `${config:<KEY>}`.
  - `regenerate(_:)` supports both `.stdio` and `.remote` single-server generated drafts, updating `${keychain:KEY}` / `${config:KEY}` references and `allowedKeys` when a field is re-tagged between secret and config.
  - **Direct form builders:**
    - `draftForRemoteServer(name:urlString:bearerToken:customHeaders:source:)` validates the URL policy (`MCPManager.remoteURLRefusal`), constructs the `.remote` `mcp.json` with `allowedKeys` and `plugin.md` manifest, and populates `secretValues` for `commit(_:)`.
    - `draftForStdioServer(name:command:args:env:source:)` constructs a `.stdio` plugin draft directly from form inputs.
- **`HarnessConfigImporter`:**
  - Adds Antigravity (`.gemini/antigravity/mcp_config.json`) to `knownLocations`.
  - `servers(at:)` accepts any server dictionary with a string `command`, `url`, `serverUrl`, or `httpUrl`.

### 2. `MCPManager` tool inspection & single-server restart

- Adds `ToolSummary` (`name`, `description`, `parameterNames`, `isReadOnly`) and `serverTools() -> [String: [ToolSummary]]` so the UI can display every connected server's discovered tools and their `readOnlyHint` status.
- Adds `restartServer(named:)` to stop and restart a single server from current config without disrupting unrelated servers.

### 3. Unified `PluginsSettingsView`

- **Sidebar:**
  - Prominent **+ Add Server** button at the top, **Reload All** button at the bottom.
  - Single unified list of managed servers/plugins and any remaining entries in `mcp_servers.json`. Every row is selectable and shows its status dot, name, transport/source badge, and a live subtitle (`Connected · N tools`, failure/config reason, or `Disabled`).
  - Removed the `Edit mcp_servers.json` link from the primary flow (replaced by native forms and a secondary "Reveal Config in Finder" action on legacy file entries).
- **Inline Add Server Workspace (shown when `+ Add Server` is selected or when no servers are configured):**
  - Mode picker: **Remote (HTTP)** · **Local (stdio)** · **Paste JSON** · **Import**.
  - **Remote (HTTP):** Server Name, Endpoint URL, Auth mode (`Bearer Token` / `Custom Header` / `None`), `SecureField` for the token, and **Add & Connect**. Writes the secret straight to `iris.plugin.<id>` via `KeychainManager.shared` (no `security` CLI, no external editor) and connects immediately.
  - **Local (stdio):** Server Name, Command, Arguments, Environment/Secret rows, and **Add & Connect**.
  - **Paste JSON:** `LiteralTextEditor` accepting any stdio or remote snippet, showing a live preview of lifted secrets before **Install & Connect**.
  - **Import:** One-click import from detected harness configs (Claude, Cursor, Windsurf, Antigravity, Gemini CLI, VS Code) plus **Install Plugin Folder...** for multi-component IPF directories.
- **Detail View (for a selected plugin or legacy file entry):**
  - Header with transport/endpoint summary, status banner (showing the full `.failed` or `.needsConfig` reason in selectable text), **Reconnect** button, and Enable toggle.
  - **Credentials & Configuration:** `SecureField` inputs with an explicit **Save & Reconnect** button (in addition to `.onSubmit`). For legacy `mcp_servers.json` entries, edits `iris.mcp` directly via `KeychainManager.shared` and offers a one-click **Convert to Managed Server** button that migrates the entry and its secrets into an isolated `iris.plugin.<id>` plugin.
  - **Discovered Tools:** Lists all tools registered by the server with their description, parameter names, and a `Read-only` vs. `Outbound-gated` badge.
