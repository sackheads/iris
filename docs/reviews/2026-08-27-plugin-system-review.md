# Peer Review: PR #96 — Plugin System (IPF manifests, Keychain secrets, Plugins settings UI)

* **Repository:** `sackheads/iris`
* **PR:** [#96](https://github.com/sackheads/iris/pull/96)
* **Author:** Eugene Archibald (`earchibald`)
* **Reviewers:** Brian Naylor (`bnaylor`, comment, 2026-09-09); Rune (`rune42808`, changes requested, 2026-09-09)
* **Spec:** `docs/specs/2026-08-27-iris-plugin-system-design.md`
* **Plan:** `docs/plans/2026-08-27-plugin-system-plan.md`
* **Date:** 2026-09-11
* **Status:** Findings addressed on the branch; awaiting re-review

---

## Executive Summary

Two independent reviews landed on the same day. Both found the architecture sound, the install path conservative (no network install, staged atomic installs, Keychain-only secrets, YAML-escaped snippet lifting), and the test coverage genuine. Both flagged the same core issue: the design doc and the code comment claimed plugin auth commands pass the Vibecop gate, and they did not. Rune added three net-new findings. Every finding was verified against the tree and is dispositioned below.

## Findings and Dispositions

| # | Finding | Source | Verified | Disposition |
|---|---|---|---|---|
| 1 | Merge conflict in `KeychainManager.swift`: branch widens `inMemorySecrets` per service; main (#97) adds `HeadlessMode.isEnabled` to `usesInMemoryStore` | both | Yes | Merged `main`; kept both sides. `--bench` still uses the in-memory store. |
| 2 | `check_command` runs `/bin/sh -c` ungated; `setup_command` calls `ToolExecutor` directly, which also applies no gate. Design doc and code comment claim both are gated. `check` auto-runs on pane open. | both | Yes — the only `requestApproval` caller was the agent tool-call path in `iris.swift` | `PluginAuthRunner.check` and `runSetup` now call `AppState.requestApproval(toolName: "run_command", …)` before executing. A denied command never runs. Approver is injectable for tests. Docs and comment corrected. |
| 3 | `${config:KEY}` values interpolate unquoted into the shell string; a saved value containing `;` or backticks is command injection (compounds #2) | bnaylor | Yes | Config values are single-quoted for the shell before substitution. Test proves a payload with `;` and backticks does not execute. Spec tells authors not to wrap references in quotes. `${keychain:}` still throws in auth commands. |
| 4 | `PluginState.pinnedBinaries` is dead: no writer outside a test, and the two readers use different keys (`binary.name` vs server name) | Rune | Yes | Removed the field, the `pinned:` parameter on `BinaryResolver.resolve`, and every doc claim of pinnable paths. `plugins.json` decoding ignores the stale key. |
| 5 | Plugin `rules/` reach the system prompt raw while workspace `AGENTS.md` passes `InjectionGuard` at tier 3 | Rune | Yes | Plugin rules now pass `PromptInjectionGuard.sanitizeUntrustedInput` then `InjectionGuard.sanitize(maxTier: .tier3_canary)`, matching `AGENTS.md`. User-authored `~/.iris/rules/` stay unguarded. Spec documents the stripped sequences and the fail-closed behavior. |
| 6 | No `docs/reviews/` artifact despite the Definition of Done | Rune | Yes | This document. |

## Trade-offs accepted

- **Approval prompt on pane open.** `check_command` still runs when the plugin detail pane loads. The first run may prompt in the main window until the user picks "Always allow"; the PermissionManager fast path is silent after that. Reviewers explicitly preferred a gated probe over an ungated one.
- **Rule content loss under the guard.** Tier 1 strips `---` and `###`, and a missing prompt-guard model blocks the rule entirely. This is the existing `AGENTS.md` behavior and is now documented for plugin authors.
- **Quoted-reference authoring rule.** `"${config:X}"` in a manifest command now yields a doubly-quoted word. The spec calls this out.

## Verified as correct by reviewers (unchanged)

- Tool descriptions from plugin servers pass `InjectionGuard` via the single `MCPManager.startServer` path.
- `PluginReferences.expand` is single-pass; substituted text is not re-scanned.
- Snippet-to-manifest YAML generation escapes backslash, quote, CR, LF, and tab; env keys are identifier-validated.
- Staged install is atomic with move-aside rollback; secrets stay in memory until commit.
- Uninstall removes the directory, the Keychain service, and the state entry, and leaves external tool credential stores alone.

## Tests

New or changed tests on the branch after review:

| Suite | Coverage added |
|---|---|
| `PluginAuthRunnerTests` | shell-quoted config expansion; `;`/backtick injection does not execute; `${keychain:}` rejected; denied approval skips `check` and `runSetup`; approver receives the expanded command |
| `SkillManagerPluginTests` | plugin rules wrapped in `<untrusted_context>`; user rules not wrapped |
| `BinaryResolverTests`, `PluginStateTests` | pin cases removed |
