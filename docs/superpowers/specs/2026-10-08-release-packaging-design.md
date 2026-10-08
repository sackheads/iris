# Release packaging, Sparkle updates, and dev/release separation

Date: 2026-10-08
Status: approved in conversation; awaiting spec review

## Goal

Ship iris as a normal, notarized macOS app that installs to `/Applications`, updates itself, and
runs side by side with dev builds without either touching the other's data. The release flow is
ported from pastefix (`../pastefix/scripts/release.sh`, `docs/RELEASING.md`), which has shipped
three Sparkle-updated releases with the same Developer ID.

## Where we are (verified 2026-10-08)

- **No updater.** `UpdateManager.swift` queries `api.github.com/repos/bnaylor/iris/releases/latest`
  and opens the release page in the browser. Nothing downloads, verifies, installs or relaunches.
  `AppState.checkForUpdates` has no callers, so `README.md:220` ("automatically checks") is false.
  `bnaylor/iris` has no releases. The repo is public.
- **The release bundle cannot work off this machine.** `scripts/build_release.sh` copies only the
  `iris` binary into `Iris.app`. The binary links `@rpath/llama.framework` with no rpath into
  `Contents/Frameworks`, and neither framework is copied. SwiftPM's generated resource accessor is:

  ```swift
  let mainPath = Bundle.main.bundleURL.appendingPathComponent("iris_iris.bundle").path
  let buildPath = "/Users/bnaylor/src/iris/.build/arm64-apple-macosx/release/iris_iris.bundle"
  ```

  For an app, `bundleURL` is the bundle root, where `codesign` rejects unsealed content. The same
  accessor is compiled into GRDB, KeyboardShortcuts, swift-crypto and swift-transformers, which we
  cannot edit. The bundle only works here because of the absolute `buildPath` fallback.
- **No MLX metallib.** `swift build` does not compile Metal shaders; no `.metallib` exists under
  `.build`. `MLXEngine` is probably non-functional in any SwiftPM build today (unverified).
- **Not notarized.** `CFBundleVersion` is always `1`. `Constants.appVersion` is a hardcoded
  `"0.1.0"` independent of the plist.
- **Dev and release share everything:** `~/.iris`, Keychain services (`com.iris.secrets`,
  `iris.mcp`, `iris.plugin.*`), and the Cmd+Shift+Space hotkey. `GUILock` overwrites rather than
  claims, so two GUIs would run against one SQLite store.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Updater | Sparkle 2 (>= 2.10.0) | Nothing to keep; a correct homegrown updater re-implements Sparkle's installer. Proven with this Developer ID in pastefix. |
| Build | Thin Xcode app target over an `IrisKit` library | Xcode's resource accessors, framework embedding, nested signing and Metal compilation. No hand-assembled bundles. |
| Architecture | arm64 only | MLX is Apple Silicon only; an Intel Mac cannot launch the app to be offered an update. |
| Data separation | Release keeps `~/.iris`; dev moves to `~/.iris-dev` | Existing data stays with the app the user relies on; a broken dev build cannot damage it. |
| Appcast | GitHub Pages, `gh-pages` branch, item prepended by script | Same as pastefix; `generate_appcast` wants every historical DMG locally. |
| EdDSA key | Separate key, Keychain account `iris` | pastefix's key occupies Sparkle's default account. Sharing it couples the two apps' roots of trust; changing `SUPublicEDKey` later strands every installed copy. |

## Section 1: identity and data separation

**Identity.** A process is a *release* build iff `Bundle.main.bundleIdentifier ==
"com.bnaylor.iris"`. Everything else is *dev*: the bare SwiftPM binary (nil bundle id) and the
Xcode Debug configuration (`com.bnaylor.iris.dev`). Keyed on the id, not on bundle presence, so
running Debug from Xcode cannot open real data. The bundle id is injectable for tests.

| | Release | Dev |
|---|---|---|
| Home | `~/.iris` | `~/.iris-dev` |
| Keychain services | `com.iris.secrets`, `iris.mcp`, `iris.plugin.<id>` | same + `.dev` suffix |
| UserDefaults domain | `com.bnaylor.iris` | `iris` / `com.bnaylor.iris.dev` (already distinct) |
| Default hotkey | Cmd+Shift+Space | Cmd+Shift+Option+Space |
| Sparkle | started | never constructed |

- The switch lives in `IrisPaths.standard` and `KeychainManager`'s service names; nothing else
  derives the home or the services. Tests already use a per-process temp home and are unaffected.
- Agent-facing strings that spell `~/.iris` literally (prompts, tool descriptions, and the
  `IrisEngine.expandTilde` path) are derived from `IrisPaths` so a dev agent is pointed at its
  own home (Invariant 9). Comments and README prose about the release layout stay as they are.

**Seeding dev: `iris --seed-dev-home`.**
- Dev identity only; refuses under the release bundle id, and refuses if `~/.iris-dev` exists and
  is non-empty.
- Copies `~/.iris` to `~/.iris-dev`, except `models/`, which is symlinked (it can be many GB).
- Copies Keychain items in-process: every item of `com.iris.secrets`, `iris.mcp` and
  `iris.plugin.*` is read and re-written under the `.dev` service. In-process rather than via
  `/usr/bin/security`, because granting `security` "Always Allow" lets any script read the keys.
  The dev binary has the signing identity that created those items, so it is expected to read
  them without prompting; confirm on first run.
- `scripts/run-dev.sh` runs it automatically when `~/.iris-dev` does not exist.

**Importing defaults into release.** Today's settings in UserDefaults (setup-wizard state, the
hotkey, toggles) live in the `iris` domain, which dev keeps. The release domain
`com.bnaylor.iris` starts empty, so a first release launch would rerun setup. On launch under the
release identity, if the release domain has never been imported (a marker key), copy every key of
the `iris` domain into it once and set the marker. Never the other direction, never twice.

**Known first-launch cost (release).** Existing Keychain items were created by the bare dev
binary (identifier `iris`). The installed `Iris.app` is a different code identity, so its first
read of each item shows the macOS access prompt; "Always Allow" once per item (about three).

**Out of scope.** `GUILock` still does not prevent two instances of the *same* identity.
LaunchServices prevents a second copy of the installed app; dev has the old behaviour.

## Section 2: project structure and build

- `Package.swift`: the current `iris` executable target becomes the `IrisKit` library (all
  sources and `assets` resources). A new `iris` executable target holds only `main.swift`
  (headless `--perf` / `--bench` / `--run-job` / `--seed-dev-home` dispatch, then
  `IrisApp.main()`). Tests use `@testable import IrisKit`. `swift build`, `swift test` and
  `scripts/run-dev.sh` keep working.
- `Iris/Iris.xcodeproj`: one app target, `Iris`, depending on the local package's `IrisKit`
  product and on Sparkle. Its `main.swift` is the same entry point.
  - Release: `com.bnaylor.iris`. Debug: `com.bnaylor.iris.dev`.
  - `ARCHS = arm64`, `MACOSX_DEPLOYMENT_TARGET = 14.0`.
  - `ENABLE_HARDENED_RUNTIME = YES`, `ENABLE_APP_SANDBOX = NO` (iris runs shell commands and
    spawns containers).
  - `Iris.entitlements` starts empty. An entitlement is added only when the notarized build is
    shown to fail without it, with the failure recorded in the commit. Never
    `com.apple.security.cs.disable-library-validation`.
- Xcode provides: resource bundles in `Contents/Resources` with accessors that find them;
  embedding and signing of llama, onnxruntime and Sparkle (including its XPC services); MLX Metal
  shader compilation.
- Versioning: `CFBundleShortVersionString` = the release argument; `CFBundleVersion` =
  `git rev-list --count HEAD` (monotonic on main). Both passed as `xcodebuild` overrides; never
  edited in the pbxproj. `Constants.appVersion` reads `Bundle.main` and falls back to `"dev"`.
- Partial `Info.plist`: `SUFeedURL = https://bnaylor.github.io/iris/appcast.xml`,
  `SUPublicEDKey`, `SUEnableAutomaticChecks = YES`, `SUScheduledCheckInterval = 86400`.
- `scripts/build_release.sh` is deleted. `scripts/sign.sh` stays for dev binaries.

**Risks.** `iris.swift` holds `IrisApp` and `@main` behaviour; moving it into a library changes
the entry point and `Bundle.module` resolution. MLX shaders have never been compiled here and may
fail on first build.

## Section 3: in-app updates and the release pipeline

**App.**
- `UpdaterController`, ported from pastefix (`Pastefix/UpdaterController.swift`): an
  implicitly-unwrapped `SPUStandardUpdaterController!` because `SPUUpdater.delegate` is read-only
  in Sparkle 2; `NSApp.activate` before a user-initiated check. Started from
  `applicationDidFinishLaunching`, and constructed only under the release identity.
- "Check for Updates…" in the app menu and the MenuBarExtra. Settings → Updates becomes Sparkle's
  automatic-check toggle, "Check Now", and version/build. `/update` triggers a Sparkle check; under
  dev it replies that updates are disabled in dev builds.
- Deleted: `UpdateManager.swift`, `UpdateManagerTests.swift`, `AppState.checkForUpdates` and its
  update state, `SettingsView`'s duplicated update state and check, and the rendering of
  GitHub's `release.body` into chat.

**`scripts/release.sh VERSION [--dry-run]`** (zsh), ported from pastefix:
1. Preconditions: clean tree, on main and pushed, tag absent locally and on origin, `gh` authed,
   notary profile works, `xmllint` present, Developer ID identity found, `SUPublicEDKey` present.
2. Resolve packages; `generate_keys --account iris -p` must equal `SUPublicEDKey`.
3. Archive (Release, arm64) and export with `method=developer-id`.
4. Verify the export: version and build; `SUFeedURL` and `SUPublicEDKey`; no `app-sandbox`
   entitlement; `Contents/Frameworks` equals an exact allowlist (Sparkle, llama, onnxruntime;
   fixed from the first dry run); no `.xctest` or stray dylibs; `codesign --verify --deep --strict`.
5. Notarize (zip) and staple the app; `spctl --assess`.
6. DMG via `hdiutil` (app + `/Applications` symlink, 5 retries, never `-quiet`); sign, notarize,
   staple.
7. `sign_update --account iris`; compose the appcast `<item>`.
8. `--dry-run` stops here.
9. Tag and push; `gh release create --verify-tag`; `curl` the asset URL until reachable; prepend
   the item to `appcast.xml` in a `gh-pages` worktree, validate with `xmllint`, push. An EXIT trap
   removes the worktree.

Carried-over gotchas: never name zsh variables `path`, `status`, `argv`, `options` or `cdpath`;
any `xmllint` output is failure; tag, release and appcast are the last three steps, in that order.
Notary profile defaults to `iris-notary`, overridable via `$NOTARY_PROFILE`.

**Docs.** `docs/releasing.md` is rewritten from pastefix's `RELEASING.md`: one-time setup, key
backup and import, `gh-pages` bootstrap, recovery after a partial release, local update testing.
README install and update sections are corrected, including the false "automatically checks"
claim, and the dev-home split is documented for contributors (AGENTS.md: dev builds use
`~/.iris-dev`).

## Verification

- Unit tests: identity resolution with an injected bundle id; dev home and Keychain service
  naming; `--seed-dev-home` refusing under release identity and over a non-empty home (against a
  temp `IrisPaths`, never the real one); the defaults import running once and only one way (own
  `UserDefaults` suites); headless mode dispatch from the new entry point.
- Each PR: full `swift test` green (exit 0, Swift Testing line, XCTest line).
- PR 3: `release.sh --dry-run` passes, including `spctl`.
- End to end, under the GUI lease: install the DMG to `/Applications`, launch, confirm real data
  loads and llama, onnx and MLX engines work under the hardened runtime. Then cut a second
  release and confirm Sparkle updates and relaunches the installed copy. The integration is not
  proven until one real update has gone through.

## Steps needing the owner

- Approval before: creating `gh-pages` and enabling Pages on `bnaylor/iris`; the first real
  `release.sh`; the second release for the update test.
- Owner-run (secrets into their Keychain): `generate_keys --account iris` plus a backup
  (`-x`, stored in the password manager, file deleted); `xcrun notarytool store-credentials
  iris-notary --team-id RMKGLPG4K4`.

## Delivery

Three PRs, each based on main:
1. Identity, dev home and Keychain separation, `--seed-dev-home`, `run-dev.sh` auto-seed, the
   one-time defaults import into the release domain.
2. `IrisKit` split and `Iris.xcodeproj`.
3. Sparkle in the app, `release.sh`, docs; then the two-release end-to-end test.
