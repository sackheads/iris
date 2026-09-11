# Iris Plugin System & Iris Plugin Format (IPF) — Design

**Date:** 2026-08-27
**Status:** Approved design, pending implementation plan

## Summary

Iris gains a plugin system. A plugin is a directory that bundles MCP servers, skills, and rules behind one OKF-style manifest. A new `PluginManager` actor loads plugins and registers each component with the existing subsystem that owns it. Secrets live in the macOS Keychain, never on disk. The legacy hand-edited `mcp_servers.json` stays a first-class, live config source. The bundle format — the Iris Plugin Format (IPF) — is documented and versioned as its own product.

| Decision | Choice |
|---|---|
| Bundle format | Own manifest (IPF, OKF-style); components in industry-standard formats (`mcpServers` JSON, Agent Skills directories per the agentskills.io spec, Markdown rules) |
| Architecture | Plugin registry (`PluginManager`) feeds existing subsystems; no new executors |
| Legacy `mcp_servers.json` | Stays live and hand-editable; shown in the same UI; gains optional `${keychain:…}` syntax |
| Secrets | Declared in manifest, collected by install wizard, stored in Keychain per-plugin |
| External auth (e.g. `nlm login`) | Orchestrated via declared setup/check commands; credentials stay in the tool's own store |
| Environment | Resolve + validate binaries (login-shell PATH + common dirs + per-server pin); Iris installs nothing |
| Install sources (v1) | Local directory; bare-MCP-server wrap; cross-harness config import (Claude, Cursor, Windsurf, Gemini CLI, Copilot) |
| Distribution registry | Out of scope for v1 |
| IPF lifecycle | Own semver, own docs tree (`docs/ipf/`), own changelog |

## Motivation

Users must be able to point Iris at an external MCP server — for example `gemini-notebook-mcp-cli` — and have it configure itself, with secrets in the Keychain and a clean Settings UI, without vendoring the server into the Iris repo. More broadly, Iris needs a plugin concept that bundles everything Iris supports (MCP, skills, rules), is compatible with industry text standards where they exist, and has a documented, independent lifecycle.

No open standard exists for the bundle layer. MCP covers tools. Agent Skills (SKILL.md plus bundled scripts/references/assets) covers skills. AGENTS.md covers project instructions. Claude Code plugins cover bundling, but they are Anthropic's product, lack a secrets/env model, and include components (hooks, agents, commands) that do not map to Iris. Therefore Iris owns the bundle manifest and reuses the standard formats for every component inside it.

## Architecture

`PluginManager` is a new actor. It does four things:

1. Discover plugin directories under `~/.iris/plugins/`.
2. Parse and validate each manifest.
3. Resolve secret and config references via `KeychainManager` and `plugins.json`.
4. Register components with existing subsystems: MCP servers into `MCPManager`, skills into the skill loader, rules into the prompt assembler.

`PluginManager` executes nothing itself. Existing subsystems keep their single jobs.

### On-disk layout

```
~/.iris/plugins/
  gemini-notebook/
    plugin.md          # IPF manifest: YAML frontmatter + Markdown docs body
    mcp.json           # standard mcpServers shape; ${keychain:…}/${config:…} refs
    skills/            # optional; Agent Skills directories (agentskills.io spec)
    rules/             # optional; plain Markdown rules
```

A plugin directory is a pure, shareable artifact. Machine-local state — enable/disable, install source, installed version, config values — lives in `~/.iris/config/plugins.json`.

### Startup data flow

1. `PluginManager.loadAll()` reads `plugins.json` and each enabled plugin's manifest.
2. Validation failure marks that plugin failed with a specific message. Other plugins load normally.
3. References resolve in memory: `${keychain:KEY}` → Keychain service `iris.plugin.<id>`; `${config:KEY}` → `plugins.json` value. An unresolvable reference puts the server in a needs-config state; it does not crash and does not block other servers.
4. Resolved `MCPServerConfig`s go to `MCPManager` alongside legacy `mcp_servers.json` entries.

Plugin server names are namespaced `<plugin-id>.<server-name>`, so collisions with the legacy file are impossible by construction. The UI shows the friendly name.

## Iris Plugin Format (IPF)

`plugin.md` is an OKF file: strict YAML frontmatter (machine-readable manifest) plus a Markdown body (human docs, rendered in the Settings detail pane).

```markdown
---
ipf: "1.0"                     # manifest schema version
id: gemini-notebook
name: Gemini Notebook
version: 1.2.0                 # plugin version, semver
description: Query and manage Gemini Notebook notebooks.
author: jacob-bd
homepage: https://github.com/jacob-bd/gemini-notebook-mcp-cli
components:
  mcp: mcp.json                # paths relative to plugin root
  skills: skills/
  rules: rules/
requires:
  binaries:
    - name: notebooklm-mcp
      install_hint: "uv tool install notebooklm-mcp-cli"
config:
  - key: NOTEBOOKLM_BASE_URL
    label: Enterprise base URL
    required: false
    help: "Set for Gemini Notebook Enterprise; leave empty for consumer."
  - key: NLM_PROFILE
    label: Auth profile
    default: default
secrets: []
auth:
  - kind: external
    label: Google account
    setup_command: "nlm login --profile ${config:NLM_PROFILE}"
    check_command: "nlm login --check"
    help: "Opens a browser to sign in to Google. Cookies auto-refresh for ~2–4 weeks."
---

# Gemini Notebook

Human-readable docs, setup notes, links…
```

### Manifest rules

- **Declarations only, never values.** `secrets` declares what the wizard must collect; values go to Keychain. `requires.binaries` declares what the environment check validates; `install_hint` is the copyable fix.
- **Components are pointers, not content.** Each component key points at a file or directory in its industry-standard format. Readers ignore unknown component keys with a warning, so IPF 1.0 readers survive 1.x manifests.
- **`id` is the identity.** Directory name, Keychain service suffix (`iris.plugin.<id>`), and MCP namespace prefix must all match it.
- **Cross-validation.** Every `${keychain:KEY}` used in `mcp.json` must appear in `secrets`, and vice versa. Validated at install and at load.

### Configuration model

| Kind | Storage | UI | Injection |
|---|---|---|---|
| `config` | `plugins.json` (plain) | Text fields | Env vars; `${config:KEY}` in `mcp.json` and commands |
| `secrets` | Keychain, service `iris.plugin.<id>` | Wizard form; masked editable fields | `${keychain:KEY}` in `mcp.json` env |
| `auth` (`kind: external`) | The tool's own store; Iris stores nothing | Status row (`check_command`, exit 0 = signed in) + Sign in button (`setup_command`) | None |

`auth.setup_command` runs as a subprocess; the tool opens its own browser if it needs one. Iris streams output and re-runs the check afterward. Both `setup_command` and `check_command` come from an untrusted manifest, so `PluginAuthRunner` routes each through `AppState.requestApproval` (PermissionManager fast path, then Vibecop, then the user prompt) before it executes — the same gate an agent-issued `run_command` gets. `ToolExecutor` applies no gate on its own, so the runner calls the gate explicitly. `${config:KEY}` values are shell-quoted as single words before substitution; `${keychain:KEY}` references are never resolved in auth commands. A future `kind: oauth` (Iris-driven flow, like the existing Google Workspace loopback OAuth) fits without schema changes.

This model covers the three real cases: plain API-key servers (`secrets` only), `nlm` consumer (external auth only), and `nlm` enterprise (`config` fields plus external auth under a different profile).

### Skills component — full Agent Skills spec

The `skills/` component contains one directory per skill, each conforming to the full Agent Skills specification (agentskills.io), not just a `SKILL.md` file:

```
skills/
  pdf-processing/
    SKILL.md           # required: YAML frontmatter + instructions
    scripts/           # optional: executable code
    references/        # optional: on-demand documentation
    assets/            # optional: templates, data files
```

Requirements on Iris:

- **Validation per spec.** At install and load: `name` rules (1–64 chars, lowercase alphanumeric + single hyphens, matches directory name), `description` present (1–1024 chars). Optional fields (`license`, `compatibility`, `metadata`, `allowed-tools`) parse without error. Spec violations fail install with the specific rule named.
- **Progressive disclosure.** Level 1: name + description register with `SkillManager` at load. Level 2: the `SKILL.md` body loads on activation (existing behavior). Level 3: `scripts/`, `references/`, and `assets/` resolve via `read_file`/`run_command` with paths relative to the skill root — the whole skill directory, not just `SKILL.md`, must be reachable by the agent.
- **Scripts run through existing gates.** Skill scripts execute via `run_command`, so they inherit sandboxing and Vibecop evaluation. Plugins get no execution bypass.
- **`allowed-tools`** is experimental in the spec; v1 parses and displays it in the plugin detail pane but does not auto-approve. Wiring it to `PermissionManager` is future work.
- **`compatibility`** is shown in the detail pane and checked loosely: it is informational text, not machine-enforced.

Iris's existing `~/.iris/memory/skills/` layout is already directory-per-skill with `SKILL.md`, so plugin skills register through the same `SkillManager` path; the plugin variant adds spec validation and keeps skill directories under the plugin root (registered by reference, not copied into the shared skills dir — uninstall stays a directory delete).

## MCP integration & secret resolution

`MCPManager` changes are deliberately small:

- **Two config sources.** `startServers()` merges legacy `mcp_servers.json` entries and plugin-provided entries.
- **Resolution at launch, in memory only.** Resolved secrets never reach disk or logs.
- **Same syntax in the legacy file.** `mcp_servers.json` env values may use `${keychain:KEY}`, resolved against shared service `iris.mcp`. Plain string values keep working unchanged.
- **Per-server status.** A status enum per server — running / stopped / failed(reason) / needs-config — observable by the Settings UI. Per-plugin start/stop, so a plugin toggle does not restart unrelated servers.
- **Binary resolution.** Commands resolve against an augmented PATH: captured once per app launch from a login shell, plus `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`. Failure surfaces the manifest's `install_hint`. Iris never installs runtimes.
- **Trust boundary unchanged.** Plugin-provided tool descriptions pass through the same `InjectionGuard` sanitization as the current MCP path. Plugin `rules/` files pass through the same guard as workspace `AGENTS.md` (`PromptInjectionGuard` structural pass, then `InjectionGuard` up to tier 3) before they reach the system prompt; only the user's own `~/.iris/rules/` are appended unguarded. Plugins get no bypass.

## Install flows

All v1 sources converge on one primitive: materialize a plugin directory under `~/.iris/plugins/<id>/`, then run the shared install wizard (validate manifest → check binaries → collect config/secrets → run auth checks → enable).

**1. Local directory.** Pick a folder or drag it onto Settings. Iris validates and copies it in. A "develop in place" toggle symlinks instead and adds a Reload button for plugin authors.

**2. Bare MCP server wrap.** Paste a standard `mcpServers` JSON snippet or type a command. Iris generates the plugin: manifest with `id` derived from the server name, the snippet as `mcp.json`. Literal env values are lifted into declarations: values that look secret (name matches `KEY|TOKEN|SECRET|PASSWORD|COOKIE`, or user marks them) become `secrets` entries with the value moved to Keychain; the rest become `config` entries. The wizard shows the classification for confirmation before it writes anything.

**3. Cross-harness import.** A picker lists detected harness configs at known locations: Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`), Claude Code, Cursor (`~/.cursor/mcp.json`), Windsurf, Gemini CLI (`~/.gemini/settings.json`), VS Code Copilot. All use the same `mcpServers` shape. Import = parse file → show servers as checkboxes → each selected server runs through flow 2's wrap-and-lift pipeline. Iris only reads those files; it never edits another harness's config.

**Uninstall** reverses the primitive: stop servers, delete the plugin directory, delete its Keychain service, remove its `plugins.json` entry. External auth credential stores (for example nlm's cookie directory) belong to the tool and are left alone; the confirm dialog says so.

All wizard writes are staged and atomic. Cancel at any step leaves no trace.

## Settings UI

A new **Plugins** tab in the existing Settings window, list plus detail.

**List pane.** One row per plugin: name, version, enable toggle, and a status LED reusing the `ModelLEDBar` visual language (green = all servers running, orange = needs configuration or sign-in, red = failed, gray = disabled). Below the plugins, a **"Configured in file"** group shows legacy `mcp_servers.json` servers with the same LEDs, an *Edit file* button, and a one-click *Convert to plugin* action (wrap-and-lift pipeline). A `FileWatcher` on the JSON hot-reloads this group on save.

**Add menu (+).** *From Folder…*, *From MCP Snippet…*, *Import from Another Harness…* — matching the three install flows.

**Detail pane**, top to bottom:

- Header: name, version, author, homepage link, install source.
- Configuration: `config` text fields, `secrets` masked fields, `auth` status rows with Sign in buttons.
- Servers & tools: each MCP server with status, resolved binary path, expandable tool list; skills and rules listed read-only with file links.
- Footer actions: *Check for Updates* (git-sourced, later), *Reveal in Finder*, *Reload* (dev-mode installs), *Uninstall*.
- The manifest's Markdown body renders at the bottom via `swift-markdown-ui`.

The install wizard is a sheet over this tab: validation → binary check (copyable `install_hint` on failure) → config/secrets form → auth sign-in step → confirm. Nothing is written before the final confirm.

## IPF lifecycle — spec as a product

The format gets its own docs tree in-repo:

```
docs/ipf/
  spec.md         # normative: manifest schema, reference syntax, component formats, validation rules
  authoring.md    # plugin-author guide with worked examples
  CHANGELOG.md
```

The spec carries its own semver, independent of Iris releases. Patch = clarifications. Minor = additive fields (old readers ignore unknowns). Major = breaking. Each Iris release states the IPF range it supports. A manifest that declares a newer major fails install with a clear "update Iris" message. When the format stabilizes, the spec can graduate to its own repo without changing anything in Iris.

**Plugin versioning (v1).** `version` is informational: shown in the UI, logged on install and update. Update checking is per-source: dev-mode = Reload; local-copy = reinstall over; git-source updates arrive with a future git install flow. No auto-update in v1.

## Error handling

A broken plugin never breaks Iris or other plugins.

| Failure | Behavior |
|---|---|
| Manifest parse/validation error | Plugin shown red with the specific message; all other plugins load |
| MCP server crash | Existing `MCPManager` behavior; surfaced per-server |
| Keychain access denied / missing secret | Needs-config state, not a launch failure |
| Missing binary | Needs-config state; UI shows `install_hint` |
| Wizard cancelled mid-flow | No trace: no directory, no Keychain items, no `plugins.json` entry |
| Manifest declares newer IPF major | Install refused with "update Iris" message |

## Testing

**Unit tests:** manifest parsing and validation; reference expansion (`${keychain:}`, `${config:}`); secret-classification heuristics; harness-config parsers with fixture files per harness; namespacing and collision rules; cross-validation of secrets vs. `mcp.json` references; Agent Skills validation against the spec's name/description rules (valid and invalid fixture skills, including `scripts/`/`references/` resolution).

**Integration test:** a trivial fixture MCP server (shell script speaking stdio JSON-RPC) exercised through install → start → tool call → uninstall.

**UI:** exercised manually, per current Iris practice.

## Out of scope (v1)

- Curated registry / marketplace.
- Git-URL install and update checking (designed for, not built).
- HTTP/streamable-HTTP MCP transport (separate future work; stdio only, matching current `MCPManager`).
- Importing Claude Code plugin *bundles* (skills+hooks); only their MCP server configs import via flow 3.
- Auto-update.
- Managed runtime installation (uv/npx downloads).

## Alternatives considered

- **Adopt Claude Code plugin format.** Rejected: Anthropic's product rather than an open standard; no secrets/env declaration layer; hooks/agents/commands do not map to Iris; Iris would track upstream changes forever.
- **Everything becomes a plugin (migrate `mcp_servers.json`).** Rejected: the hand-editable text file must stay live; migration surprises users who sync the file across machines.
- **Text files stay canonical; plugins are installers.** Rejected: update/uninstall need ownership tracking inside shared files; JSON has no comments, so provenance needs sidecar state anyway; secrets references would leak Iris-specific syntax into otherwise standard files.
