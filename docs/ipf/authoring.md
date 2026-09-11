# Authoring an Iris Plugin

This guide walks through two complete plugins. Copy either one as a
starting point. For the full field-by-field rules, see
[spec.md](spec.md).

## Summary

| Example | Configuration kind | Shows |
|---|---|---|
| `postgres-tools` | `secrets` only | The simplest shape: a single API-key/connection-string MCP server |
| `gemini-notebook` | `config` + `auth` (`kind: external`) | A server with a named profile and browser-based sign-in |

Both examples are single-server plugins: one `plugin.md`, one `mcp.json`,
no `skills/` or `rules/`. Add `skills/` or `rules/` directories the same
way you would to any plugin — see spec.md's "Components" section.

## Example 1: a plain API-key server (`postgres-tools`)

This is the shape most MCP servers need: one binary, one secret, no
special sign-in flow.

### `plugin.md`

```markdown
---
ipf: "1.0"
id: postgres-tools
name: Postgres Tools
version: 0.1.0
description: Query and inspect a Postgres database over MCP.
author: your-name
homepage: https://github.com/your-name/postgres-tools-mcp
components:
  mcp: mcp.json
requires:
  binaries:
    - name: postgres-mcp
      install_hint: "uv tool install postgres-mcp"
secrets:
  - key: DATABASE_URL
    label: Database connection string
    required: true
    help: "postgres://user:pass@host:5432/dbname"
---

# Postgres Tools

Exposes read/write tools against a Postgres database: run queries, list
tables, describe schemas.

## Setup

1. Install `postgres-mcp`: `uv tool install postgres-mcp`.
2. Install this plugin and paste your connection string when prompted.
3. Enable the plugin. The status LED turns green once the binary is found
   and the connection string is saved.

## Notes

The connection string is stored in the macOS Keychain under service
`iris.plugin.postgres-tools`. It is never written to the plugin directory
or to Iris logs.
```

### `mcp.json`

```json
{
  "postgres": {
    "command": "postgres-mcp",
    "args": ["--transport", "stdio"],
    "env": {
      "DATABASE_URL": "${keychain:DATABASE_URL}"
    }
  }
}
```

Notice the `${keychain:DATABASE_URL}` reference matches the `secrets`
entry's `key` exactly. This is the cross-validation rule from spec.md: if
you rename the secret in one file, rename it in the other or the plugin
fails to load with an "undeclared secret" error.

Once installed, this server registers with Iris as
`postgres-tools.postgres` — the `<id>.<server-name>` namespacing keeps it
distinct from any legacy `mcp_servers.json` entry with the same server
name.

### Test your plugin

1. Put the two files above in a folder named `postgres-tools` (the folder
   name must equal the manifest's `id`).
2. Open Iris → Settings → Plugins → **+ → From Folder…**.
3. Pick the folder. The install wizard validates the manifest, checks for
   the `postgres-mcp` binary, and — because `DATABASE_URL` is a declared
   secret — shows a masked field for it in the Configuration step.
4. Iris copies the folder on install. To pick up later edits to the
   source files, reinstall the folder (**+ → From Folder…** again) —
   installs of the same `id` replace the previous copy.
5. After confirming, find `postgres-tools` in the Plugins list. The status
   LED is:
   - **Orange** (needs configuration) if the binary is missing or the
     secret is still empty — the detail pane shows the specific reason.
   - **Green** once the binary resolves and the secret is filled in.
   - **Red** if `plugin.md` fails to parse, or `mcp.json` uses a
     `${keychain:...}` key that is not in `secrets` — the detail pane
     shows the exact validation error from `IPFManifest`/`PluginManager`.
6. Errors surface in the detail pane's status text and, for MCP process
   failures, in the expandable tool list under "Servers & tools."

## Example 2: config + external auth (`gemini-notebook`)

This plugin adds a named config profile and a tool with its own
browser-based sign-in, instead of an API key.

### `plugin.md`

```markdown
---
ipf: "1.0"
id: gemini-notebook
name: Gemini Notebook
version: 1.2.0
description: Query and manage Gemini Notebook notebooks.
author: jacob-bd
homepage: https://github.com/jacob-bd/gemini-notebook-mcp-cli
components:
  mcp: mcp.json
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

Query and manage Gemini Notebook (NotebookLM) notebooks from Iris.

## Setup

1. Install `notebooklm-mcp-cli`: `uv tool install notebooklm-mcp-cli`.
2. Install this plugin. Leave "Enterprise base URL" empty unless your
   organization runs Gemini Notebook Enterprise.
3. Click **Sign in** in the plugin's detail pane. This runs
   `nlm login --profile default` in a subprocess, which opens a browser
   for you to authenticate with Google.
4. The status row re-checks automatically after sign-in
   (`nlm login --check`) and turns green on success.

## Notes

Iris never sees or stores your Google credentials. `nlm` manages its own
cookie store; uninstalling this plugin does not touch it.
```

### `mcp.json`

```json
{
  "notebook": {
    "command": "notebooklm-mcp",
    "args": ["--transport", "stdio"],
    "env": {
      "NOTEBOOKLM_BASE_URL": "${config:NOTEBOOKLM_BASE_URL}",
      "NLM_PROFILE": "${config:NLM_PROFILE}"
    }
  }
}
```

Both env values reference `config` keys, not `secrets` — there is no
Keychain entry for this plugin at all (`secrets: []`). Authentication is
handled entirely by the `auth` block and `nlm`'s own credential store.

### Test your plugin

1. Put the two files above in a folder named `gemini-notebook`.
2. Settings → Plugins → **+ → From Folder…**, pick the folder.
3. The wizard checks for the `notebooklm-mcp` binary, then shows the two
   `config` fields in the Configuration step (base URL, profile — profile
   pre-filled with its `default`).
4. The Configuration step also **displays** the `auth` block's label and
   its `setup_command`/`check_command` so you can see what will run — the
   wizard never executes them. Sign-in happens after install, from the
   plugin's detail pane. Nothing is written until you press Install.
5. After install, the detail pane shows a status row driven by
   `check_command`. Orange with "not signed in" until you click **Sign
   in**; the subprocess output streams into the pane while `nlm` opens
   your browser. Once `nlm login --check` exits 0, the row turns green.
6. If `notebooklm-mcp` is not on `PATH`, the plugin shows `needsConfig`
   with the `install_hint` text (`uv tool install notebooklm-mcp-cli`)
   printed verbatim so you can copy-paste it.

## Common mistakes

| Mistake | What happens | Fix |
|---|---|---|
| Manifest `id` does not match the folder name | Install fails: "Manifest id does not match directory name" | Rename the folder or the `id` field so they match |
| `id` has uppercase letters or underscores | Install fails: invalid id | Use `^[a-z0-9]+(-[a-z0-9]+)*$` only |
| `${keychain:KEY}` in `mcp.json` with no matching `secrets` entry | Plugin loads as `.failed`, not `.needsConfig` | Add a `secrets` entry with that exact `key`, or remove the reference |
| Env key in `mcp.json` outside `[A-Za-z0-9_]+` | Rejected at install (snippet-wrap flow) | Rename the env var |
| `ipf: "2.0"` or similar | Install refused with an "update Iris" message | Use `ipf: "1.0"` unless you are targeting a documented later major |

## Where to go next

- [spec.md](spec.md) — the normative manifest schema, reference syntax,
  and component formats.
- [CHANGELOG.md](CHANGELOG.md) — IPF version history.
