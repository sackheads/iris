# Iris Plugin Format (IPF) Specification

Version: **1.0.0**
Status: Stable. This is the normative reference for IPF 1.x.
Changelog: [CHANGELOG.md](CHANGELOG.md)

This spec defines the on-disk format that Iris plugins use. It covers the
manifest schema, the reference syntax for config and secret values, the
component formats, and the validation rules that Iris applies at install
and at load. Where this document and the Iris source disagree, the source
is the bug — file an issue. This revision was checked directly against
`Sources/iris/IPFManifest.swift`, `Sources/iris/PluginReferences.swift`,
`Sources/iris/PluginManager.swift`, and `Sources/iris/PluginInstaller.swift`.

## Summary

| Topic | Rule |
|---|---|
| Manifest file | `plugin.md`: YAML frontmatter (`---` … `---`) followed by a Markdown body |
| `id` | `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 64 characters, must equal the plugin's directory name |
| `ipf` version | Any `1.x` is accepted; any other major is refused with an "update Iris" message |
| Required manifest fields | `ipf`, `id`, `name`, `version` |
| Components | `mcp` (stdio MCP server config), `skills` (Agent Skills directories), `rules` (Markdown files) |
| Reference syntax | `${keychain:KEY}` and `${config:KEY}`; key charset `[A-Za-z0-9_]+` |
| Cross-validation | Every `${keychain:KEY}` in `mcp.json` must be declared in `secrets`, or the plugin fails to load |
| Config storage | `config` → `~/.iris/config/plugins.json` (plain); `secrets` → Keychain service `iris.plugin.<id>`; `auth` → the tool's own store |
| `version` field | Informational only in IPF 1.0. Iris does not act on it. |

## Directory layout

A plugin is a directory. Iris looks for it under `~/.iris/plugins/<id>/`.

```
<id>/
  plugin.md          # required: IPF manifest (YAML frontmatter) + human docs (Markdown body)
  mcp.json            # optional: present only if components.mcp is set
  skills/             # optional: present only if components.skills is set
  rules/              # optional: present only if components.rules is set
```

| Path | Role |
|---|---|
| `plugin.md` | The manifest. YAML frontmatter declares identity, components, and configuration needs. The Markdown body is human-readable documentation, rendered in the Settings detail pane. |
| `mcp.json` | Standard `mcpServers` JSON. Declares the plugin's MCP server(s), stdio transport only. |
| `skills/` | One directory per skill, each a full Agent Skills bundle (see "Components" below). |
| `rules/` | Plain Markdown files. Each file is appended to the base system prompt, in filename order, after injection-guard sanitization. |

A plugin directory is a pure, shareable artifact. It carries no machine-local
state. Enable/disable flags, install source, installed version, and
config values live outside the plugin, in `~/.iris/config/plugins.json`.

## Manifest schema

The manifest is the YAML frontmatter of `plugin.md`, decoded against
`IPFManifest` in `Sources/iris/IPFManifest.swift`. Field names below match
the Swift struct exactly.

| Field | Type | Required | Constraints |
|---|---|---|---|
| `ipf` | string | yes | Manifest schema version, e.g. `"1.0"`. Only the major component is checked: any `1.x` is accepted. |
| `id` | string | yes | `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 64 characters. Must equal the plugin's directory name, or the manifest fails to parse. |
| `name` | string | yes | Human-readable display name. No format constraint. |
| `version` | string | yes | Plugin version. Free-form in IPF 1.0 (semver is recommended but not enforced). Informational only — see "Versioning policy". |
| `description` | string | no | One-line summary. |
| `author` | string | no | Author name or handle. |
| `homepage` | string | no | URL, shown as a link in the detail pane. |
| `components` | object | no | See `components.mcp`, `components.skills`, `components.rules` below. |
| `requires.binaries` | array | no | Each entry has `name` (required) and `install_hint` (optional, shown verbatim on a missing-binary error). |
| `config` | array | no | Each entry: `key` (required), `label`, `required` (bool), `default`, `help`. |
| `secrets` | array | no | Each entry: `key` (required), `label`, `required` (bool), `help`. Never carries a value — only a declaration. |
| `auth` | array | no | Each entry: `kind` (required; IPF 1.0 defines only `"external"`), `label`, `setup_command`, `check_command`, `help`. |

### `components` sub-fields

| Field | Type | Meaning |
|---|---|---|
| `components.mcp` | string | Path, relative to the plugin root, to an `mcpServers`-shaped JSON file. |
| `components.skills` | string | Path, relative to the plugin root, to a directory of Agent Skills bundles. |
| `components.rules` | string | Path, relative to the plugin root, to a directory of Markdown rule files. |

All three are optional and independent — a plugin may declare only `mcp`,
only `skills`, only `rules`, or any combination. Iris reads component keys
it recognizes and ignores unknown keys silently, so an IPF 1.0 reader
survives a manifest written against a later 1.x minor that adds a new
component kind.

### The `id` rule

`id` is the plugin's identity everywhere in Iris:

- It is the plugin's directory name (`~/.iris/plugins/<id>/`). A mismatch
  between the manifest's `id` and the directory name fails manifest parsing.
- It is the Keychain service suffix: secrets live under service
  `iris.plugin.<id>`.
- It is the MCP server namespace prefix: a server named `search` in a
  plugin `id: acme-tools` registers as `acme-tools.search`, so plugin
  servers can never collide with each other or with the legacy
  `mcp_servers.json` namespace.

Pattern: `^[a-z0-9]+(-[a-z0-9]+)*$` — lowercase letters and digits, with
single hyphens as separators. No leading, trailing, or doubled hyphens. No
uppercase, underscores, or other punctuation. Maximum length 64 characters.

### The `ipf` version rule

The `ipf` field states the manifest schema version. Iris parses only the
part before the first dot as the major version and compares it to the
major version it supports (`1` in this release). Any `1.x` manifest is
accepted, regardless of minor. Any other major (`0.x`, `2.x`, …) is
refused at parse time with the message: "Manifest declares ipf `<version>`;
this Iris supports 1.x. Update Iris."

## Reference syntax

Manifest and `mcp.json` values may reference configuration and secrets
instead of hardcoding them, using two forms:

| Form | Resolves against | Where it may appear |
|---|---|---|
| `${keychain:KEY}` | The plugin's Keychain entries (service `iris.plugin.<id>`) | `mcp.json` env values; `auth.setup_command` / `auth.check_command` |
| `${config:KEY}` | The plugin's config values in `plugins.json` | `mcp.json` env values; `auth.setup_command` / `auth.check_command` |

`KEY` matches `[A-Za-z0-9_]+` — letters, digits, and underscore only. No
other characters are valid inside the braces.

Expansion happens in memory, at server-launch or command-run time only.
Expanded values are never written to disk or to logs.

### Cross-validation rule

Every `${keychain:KEY}` reference that appears in `mcp.json` must have a
matching entry in the manifest's `secrets` list, and every declared secret
should be referenced somewhere it is used. Iris enforces the first
direction strictly: a `${keychain:KEY}` in `mcp.json` with no matching
`secrets` entry fails the plugin with "mcp.json references
`${keychain:KEY}` but the manifest does not declare it" — this is a load
failure (`.failed`), not a recoverable configuration gap. This check runs
both at install time and every time plugins load.

An unresolved `${config:KEY}` or a declared-but-missing `${keychain:KEY}`
value (the key is declared correctly but the user has not filled it in
yet) is different: it puts the plugin in a needs-config state rather than
failing it. See "Readiness semantics" below.

## Components

### `mcp` — MCP servers

`components.mcp` points at a JSON file in the **bare server-object shape**
only: a top-level object mapping server name to `{ command, args, env }`.
This is the required on-disk format. Iris supports **stdio transport only**
in this release; there is no HTTP or streamable-HTTP transport.

**Warning:** An `mcp.json` file wrapped in a `{"mcpServers": {...}}` object
will load zero servers silently while the plugin still shows a green status.
The bare form is required.

The install wizard's *From MCP Snippet* flow accepts `mcpServers`-wrapped
JSON as a convenience — you can paste an `mcpServers` block directly — and
generates the bare form into the plugin's `mcp.json` file.

Env values may use `${keychain:KEY}` and `${config:KEY}` references, which
resolve immediately before the server process launches. Literal string
values are also valid and pass through unchanged — this is the same
syntax and behavior as the legacy `mcp_servers.json` file, so an `mcp.json`
authored for a plugin looks exactly like a legacy server entry.

Env variable keys used inside `mcp.json`'s `env` map are restricted to the
identifier charset `^[A-Za-z0-9_]+$`. A key outside that charset is
rejected at install time (this applies specifically to the MCP-snippet
wrap flow, which validates every incoming env key before generating a
plugin).

### `skills` — Agent Skills

`components.skills` points at a directory containing one subdirectory per
skill. Each skill directory conforms to the full Agent Skills specification
([agentskills.io](https://agentskills.io)), not just a single `SKILL.md`
file:

```
skills/
  pdf-processing/
    SKILL.md           # required: YAML frontmatter + instructions
    scripts/           # optional: executable code
    references/        # optional: on-demand documentation
    assets/            # optional: templates, data files
```

Validation, at install and at load:

- `name`: 1–64 characters, lowercase alphanumeric with single hyphens,
  and must match the skill's directory name.
- `description`: present, 1–1024 characters.
- Optional fields `license`, `compatibility`, `metadata`, and
  `allowed-tools` parse without error when present.
- A spec violation fails the whole plugin's load with the specific rule
  named (skill validation failures are `.failed`, not `.needsConfig`).

Progressive disclosure follows the same three levels as the wider Agent
Skills spec: name and description register at load (level 1); the
`SKILL.md` body loads on activation (level 2); `scripts/`, `references/`,
and `assets/` resolve on demand via `read_file`/`run_command` with paths
relative to the skill root (level 3). Skill scripts run through the same
`run_command` sandboxing and Vibecop evaluation as any other command —
plugins get no execution bypass.

When a plugin skill's name collides with a built-in skill's name, both
appear in skill discovery, but the built-in skill wins for body lookup.

`allowed-tools` is experimental in the Agent Skills spec. IPF 1.0 parses
and displays it in the plugin detail pane but does not auto-approve
anything; wiring it to the permission system is future work.
`compatibility` is shown as informational text and is not machine-enforced.

### `rules` — always-on prompt text

`components.rules` points at a directory of plain Markdown files. Every
`.md` file in that directory (in filename order, hidden files excluded) is
appended to the base system prompt. Rules carry no frontmatter and no
special syntax.

Plugin rules are third-party content, so Iris treats them like a
workspace `AGENTS.md` rather than like the user's own `~/.iris/rules/`:
each file passes the prompt-injection guard (structural normalization,
then the model-backed tiers when enabled) and is wrapped in an
`<untrusted_context>` block before it reaches the prompt. Consequences
for authors:

- Role-delimiter strings (`system:`, `assistant:`, `user:`) and the
  sequences `---` and `###` are stripped. Use `#` or `##` headings and
  avoid horizontal rules.
- If the model-backed tiers are enabled but no prompt-guard model can
  load, the guard fails closed and the rule is blocked for that session.

### Unknown component keys

A `components` block may contain keys this Iris version does not
recognize. Unknown keys are ignored silently, rather than failing the
plugin. This lets an older Iris load a manifest written against a newer
IPF 1.x minor that introduced an additional component kind.

## Configuration model

IPF distinguishes three kinds of configuration input, each with its own
storage, UI treatment, and injection mechanism.

| Kind | Storage | UI | Injection |
|---|---|---|---|
| `config` | `~/.iris/config/plugins.json`, plain text | Text fields in the plugin detail pane | Available as `${config:KEY}` in `mcp.json` and in `auth` commands |
| `secrets` | macOS Keychain, service `iris.plugin.<id>` | Install-wizard form; masked, editable fields | Available as `${keychain:KEY}` in `mcp.json` env |
| `auth` (`kind: external`) | The external tool's own store; Iris stores nothing | A status row (driven by `check_command`) plus a "Sign in" button (`setup_command`) | None — external auth is never referenced from `mcp.json` |

`secrets` and `config` entries are declarations, never values: the
manifest states what the wizard must collect (`key`, `label`, `required`,
`help`, and for `config` a `default`); the actual value is supplied by the
user at install or edit time and stored outside the plugin directory.

### `kind: external` semantics

IPF 1.0 defines one `auth` kind: `external`. It models tools that manage
their own credential store (browser cookie jars, CLI-managed tokens) where
Iris's job is only to trigger and observe, not to hold secrets.

| Field | Meaning |
|---|---|
| `setup_command` | Runs as a subprocess when the user clicks "Sign in." May open a browser itself. Iris streams its output and re-runs `check_command` afterward. |
| `check_command` | Runs to determine sign-in status. **Exit code 0 means signed in; any non-zero exit means not signed in.** This is the entire contract — no output parsing. |
| `label` | Text shown next to the status row (e.g. "Google account"). |
| `help` | Explanatory text shown near the Sign in button. |

Both `setup_command` and `check_command` may use `${config:KEY}`
references (for example, to pass a per-profile name). Each `${config:KEY}`
value is substituted as one single-quoted shell word, so do not wrap the
reference in quotes yourself: write `--profile ${config:PROFILE}`, not
`--profile "${config:PROFILE}"`. `${keychain:KEY}` references are not
allowed in auth commands; a command that contains one is reported as
unresolvable and never runs.

Both commands pass the same permission gate as any other command Iris
runs (persisted "always allow" rules, then Vibecop, then a user prompt)
before they execute. `setup_command` then runs through `run_command`;
`check_command` runs via `/bin/sh -c`. Both commands are displayed to the
user at install time, in the wizard's Configuration step. `check_command`
also runs whenever the plugin's settings pane is shown, to refresh the
status row, so the first open may prompt for approval until the user
chooses "Always allow".

This model covers three real cases: a plain API-key server (`secrets`
only, no `auth`), a tool with only external browser-based sign-in (`auth`
only, no `config`/`secrets`), and a tool with both a named profile and
external sign-in (`config` plus `auth`).

### Readiness semantics

Iris evaluates each enabled plugin's readiness on every load
(`PluginManager.evaluateReadiness`) and reports one of four statuses:

| Status | Meaning | Triggers |
|---|---|---|
| `ok` | Fully configured and loaded | All required secrets, config, and binaries present; no undeclared references |
| `needsConfig(reason)` | Recoverable — the plugin is valid but not yet usable | Missing required secret or config value; missing required binary (`install_hint` shown); a declared `${keychain:KEY}`/`${config:KEY}` reference whose value is not yet filled in |
| `failed(reason)` | Load or validation error | `plugin.md` missing or unparseable; unsupported `ipf` major; invalid or mismatched `id`; an `mcp.json` `${keychain:KEY}` reference not declared in `secrets`; a skill in `skills/` that fails Agent Skills validation |
| `disabled` | User has turned the plugin off | The plugin's `plugins.json` entry has `enabled: false` |

A plugin in `needsConfig` or `failed` never blocks any other plugin from
loading. `needsConfig` is recoverable purely through the Settings UI
(filling in a field, installing a binary); `failed` requires fixing the
plugin's files.

## Versioning policy

IPF itself carries its own semver, independent of Iris's release version:

| Bump | Meaning |
|---|---|
| Patch | Wording clarifications to this spec. No schema change. |
| Minor | Additive schema changes only — new optional fields, new component or `auth` kinds. Old readers keep working because unknown fields and unknown component keys are ignored. |
| Major | Breaking changes — removed fields, changed semantics for an existing field, or a validation rule that would newly reject previously valid manifests. |

A manifest's `ipf` field states the schema version it was written against.
Iris accepts any manifest whose major matches its supported major (`1` in
this release) and refuses any other major with an "update Iris" message,
as described under "The `ipf` version rule" above.

The manifest's own `version` field is a separate thing: the **plugin's**
version, not the schema's. In IPF 1.0, `version` is purely informational —
Iris shows it in the UI and logs it on install and update, but does not
act on it. There is no update-checking or compatibility gating driven by
`version` in this release.
