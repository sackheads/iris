# Releasing Iris

Iris ships as a notarized DMG from GitHub Releases and updates itself via Sparkle, reading
`https://sackheads.github.io/iris/appcast.xml` (the `gh-pages` branch). `scripts/release.sh` does
the whole thing from a maintainer's machine.

## One-time setup (per maintainer machine)

1. **Developer ID.** A `Developer ID Application` certificate for team `RMKGLPG4K4` in the login
   keychain. The script picks the first one it finds; override with
   `CODESIGN_IDENTITY="Developer ID Application: … (RMKGLPG4K4)"`.
2. **Notary credentials.** Interactive, once:
   ```sh
   xcrun notarytool store-credentials iris-notary --team-id RMKGLPG4K4
   ```
   Use an App Store Connect API key, or your Apple ID plus an app-specific password from
   appleid.apple.com. Verify with `xcrun notarytool history --keychain-profile iris-notary`.
   Override the profile name with `NOTARY_PROFILE`.
3. **Sparkle EdDSA private key, under the `iris` Keychain account.** This is the root of trust
   for every installed copy: an update signed with any other key is rejected, and a lost key
   means no installed copy can ever update again. The public half is in `App/Info.plist`
   (`SUPublicEDKey`).

   **Never run `generate_keys` or `sign_update` without `--account iris`.** This machine's
   *default* Keychain account already holds a different project's (pastefix's) signing key, so a
   bare `generate_keys -p` prints *that* project's public key, not Iris's — and a bare
   `sign_update` would sign the DMG with the wrong key, producing an appcast item every installed
   copy of Iris rejects.
   - Import an existing key on a new machine:
     `generate_keys --account iris -f /path/to/exported-key.txt`
   - Confirm the keychain key matches the app:
     `generate_keys --account iris -p` must print exactly the `SUPublicEDKey` value in
     `App/Info.plist`.
   - `generate_keys` lives in the Sparkle SPM artifact once the package has been resolved:
     `swift package resolve && .build/artifacts/sparkle/Sparkle/bin/generate_keys --account iris -p`.
     (`scripts/release.sh` resolves packages itself through Xcode's own DerivedData when it runs;
     this path is for key setup done outside a release.)
   - **Never** run a bare `generate_keys --account iris` on a machine that lacks the key expecting
     to "regenerate" it. Restore from the backup export instead.
   - **Back up the private key before cutting a release.** The procedure: run
     `generate_keys --account iris -x ~/Desktop/iris-sparkle-private-key.txt`, store the file's
     contents in the owner's password manager, delete the file, and check that iCloud Drive's
     Desktop & Documents sync has not already uploaded a copy (if it has, delete it there too).
     Until the owner confirms the key is in the password manager, treat the Keychain copy as the
     only one.
4. **`brew install xcodegen`** and the **Metal Toolchain**
   (`xcodebuild -downloadComponent MetalToolchain`) — see `AGENTS.md`'s "Building the Xcode app".
   MLX's shaders are compiled into a `.metallib` by the Xcode build, never by `swift build`, and
   `scripts/gen-xcodeproj.sh` (which both `release.sh` and `scripts/build-app.sh` run first)
   needs `xcodegen` to regenerate `Iris.xcodeproj` from `project.yml`.
5. **`gh`** authenticated with push access to `sackheads/iris` (`gh auth login`). The repo must
   be public: Sparkle downloads the release DMG anonymously, so a private repo's asset is a 404 to
   every installed copy, and the script refuses to run unless `gh repo view` reports `PUBLIC`.
6. **About 25 GB free disk.** Each run's archive, export and DMG live under a `mktemp -d` work
   directory under `$TMPDIR`, printed as `work dir: …` as soon as it's created; delete it when
   done.
7. **Export signing certificate.** `scripts/ExportOptions.plist` names the generic
   `signingCertificate` "Developer ID Application" rather than one exact identity. If more than
   one Developer ID Application certificate is in the keychain (e.g. an old, expired one left
   behind), `-exportArchive` may pick a different certificate than the `CODESIGN_IDENTITY` the
   archive step used. Remove expired certificates from the keychain, or edit the plist's
   `signingCertificate` to the exact certificate name, to avoid the mismatch.

The `gh-pages` branch and GitHub Pages were bootstrapped on 2026-10-08 and already exist. The
recipe below is kept for disaster recovery only — do not re-run it against a working `gh-pages`.
If it ever needs recreating: an orphan branch with an `appcast.xml` containing an empty `<channel>`
(title, link, description, language) and a `.nojekyll`, then
`gh api -X POST repos/sackheads/iris/pages -f "source[branch]=gh-pages" -f "source[path]=/"`.

## Cutting a release

From a clean, pushed `main`:

```sh
scripts/release.sh 1.2.3 --dry-run   # builds, notarizes, DMGs, signs, prints the appcast item; publishes nothing
scripts/release.sh 1.2.3             # the same, then tags v1.2.3, creates the GitHub release, pushes the appcast
```

Before building anything, the script checks (in both modes): the Metal Toolchain runs; the
working tree is clean; `origin/gh-pages` can be fetched; on `main` with `HEAD` pushed to
`origin/main` (unless `RELEASE_ALLOW_BRANCH=1`, below); the tag exists neither locally nor on
`origin`; `gh` is authenticated and `sackheads/iris` is public; the notary profile works;
`xmllint` exists; a team `RMKGLPG4K4` Developer ID identity is available; `App/Info.plist` has a
`SUPublicEDKey`; and the build number is newer than every `<sparkle:version>` already in
`appcast.xml` on `gh-pages`. Sparkle only offers a build higher than the installed one, so
re-releasing the same commit under a new version would reach nobody: land a commit on `main`
first. After resolving packages it also checks that the Keychain's `iris` EdDSA key matches
`SUPublicEDKey`.

Any second argument other than exactly `--dry-run` is rejected. `RELEASE_ALLOW_BRANCH=1` skips
the `main`/pushed-to-origin checks so a release can be dry-run tested from a feature branch; the
script refuses to honor it without `--dry-run`, and a real release must never set it.

What it does, in order: archive (Release, Developer ID, hardened runtime, **arm64 only** —
`-destination 'generic/platform=macOS'` with `ARCHS=arm64`, because MLX and the local engines need
Apple Silicon and an Intel Mac could never launch the app to be offered an update) → export →
notarize + staple the app → DMG → sign + notarize + staple the DMG → `sign_update --account iris`
(EdDSA) → tag → `gh release create` with the DMG → prepend an `<item>` to `appcast.xml` on
`gh-pages`. Every step is fatal. The three irreversible steps (tag, release, appcast) are last and
adjacent.

Right after export, the script also asserts that the exported bundle carries the correct
`SUFeedURL` and `SUPublicEDKey`, does **not** carry the `app-sandbox` entitlement, has exactly the
expected `Contents/Frameworks` (`Sparkle.framework`, `llama.framework`, `onnxruntime.framework`,
plus the `libswiftCompatibilitySpan.dylib` back-deploy dylib Xcode embeds unprompted) with no
stray test or dylib artefacts, that every signed piece (the app, its frameworks, Sparkle's
`Autoupdate`/`Updater.app`/XPC services) is signed by team `RMKGLPG4K4` without the
`get-task-allow` entitlement, and that the built binary's architecture is exactly `arm64`.

Versions: the argument becomes `CFBundleShortVersionString`; `CFBundleVersion` (what Sparkle
compares) is `git rev-list --count HEAD`. No version-bump commit is needed or wanted, but every
release needs at least one new commit on `main` since the last one (the build-number check above).

Release notes are whatever `gh release create --generate-notes` produces from merged PRs; the
appcast links to the release page. Edit the release on GitHub afterwards if the generated notes
need help.

Each run leaves its work directory (DerivedData, archive, DMG) under `$TMPDIR`; delete it when
done. The script prints it (`work dir: …`) as soon as it's created.

## If something goes wrong

- **Notarization rejected.** The script prints the notary log. Usual causes: a nested binary not
  signed with the Developer ID (check `scripts/ExportOptions.plist`), or hardened runtime off on
  a configuration.
- **Wrong key.** If `generate_keys --account iris -p` disagrees with `SUPublicEDKey` in
  `App/Info.plist`, stop. Restore the correct private key from backup. Do not change the public
  key in the app to match a new private key: every installed copy would stop updating.

### Recovery after a failure at or past the tag

The script creates the tag locally, pushes it, creates the GitHub release, checks the DMG's
download URL, then pushes the appcast. Its preconditions refuse a tag that already exists locally
or on `origin`, so a failure part-way needs cleaning up before a re-run.

- If **`git push origin "$TAG"` failed**, the tag exists only locally: `git tag -d vX.Y.Z`, fix
  what stopped the push, then re-run `scripts/release.sh X.Y.Z`.
- If **`gh release create` failed and no release exists** (`gh release view vX.Y.Z` says not
  found): `git push --delete origin vX.Y.Z && git tag -d vX.Y.Z`, then re-run.
- If **`gh release create` failed but a release exists** (for example, created without its DMG):
  `gh release delete vX.Y.Z --yes --cleanup-tag && git tag -d vX.Y.Z` (`gh` deletes the release
  and the tag on origin; it does **not** delete the local tag, and a leftover local tag blocks the
  script's "tag already exists" precondition), then re-run.
- If **the release was created but the asset-reachability check failed** ("release asset not
  reachable at …"), do not delete the release; GitHub's CDN is usually just slow. Wait a few
  minutes and check the URL the script printed with `curl -fsSLI <url>`. Once it answers, take the
  appcast-only path below.
- If **only the appcast step failed** (or you are finishing after the reachability check), the
  release itself is fine and doesn't need undoing — paste the saved item file (the script prints
  `item file: $ITEM_FILE` when it composes the item) into `appcast.xml` on `gh-pages` by hand: as
  the first `<item>` in `<channel>`, check it with `xmllint --noout`, commit, push.
- If the script was interrupted between adding and removing its `gh-pages` worktree, run
  `git worktree prune`. Normally an `EXIT` trap removes the worktree even on failure, but a
  killed process can skip it.

## Testing an update locally without publishing

Iris's dev builds (`swift run`, `scripts/run-dev.sh`, the Xcode Debug app) never check for
updates at all — `UpdaterController.shared` is `nil` unless the running bundle is the installed
app's identity (`com.bnaylor.iris`). So a local update test needs two **Release**-configuration
builds, both reporting bundle id `com.bnaylor.iris`, with different `CURRENT_PROJECT_VERSION`
values:

```sh
scripts/gen-xcodeproj.sh
# Pin to the same dependency revisions `swift test`/`build-app.sh` used: swift-sdk and
# llama.swift track branch main, so an unpinned xcodebuild here could resolve different commits
# than the ones actually tested. Both xcodebuild invocations below pass
# -disableAutomaticPackageResolution to build from this pinned Package.resolved rather than
# re-resolving (mirrors scripts/build-app.sh and scripts/release.sh).
mkdir -p Iris.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved Iris.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

xcodebuild build -project Iris.xcodeproj -scheme Iris -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/iris-updatetest-old \
  -skipPackagePluginValidation -skipMacroValidation -disableAutomaticPackageResolution \
  MARKETING_VERSION=1.0.0 CURRENT_PROJECT_VERSION=900000

xcodebuild build -project Iris.xcodeproj -scheme Iris -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/iris-updatetest-new \
  -skipPackagePluginValidation -skipMacroValidation -disableAutomaticPackageResolution \
  MARKETING_VERSION=1.0.1 CURRENT_PROJECT_VERSION=900001
```

`scripts/build-app.sh` does not forward extra `xcodebuild` settings (it takes only
`[Debug|Release] [derived-data-dir]`, with no passthrough for `MARKETING_VERSION`/
`CURRENT_PROJECT_VERSION` overrides), so the version-pinned builds above call `xcodebuild`
directly rather than through it — but otherwise match it step for step: regenerate the project,
seed its `Package.resolved`, then build with the same `-skip*`/`-disableAutomaticPackageResolution`
flags. `project.yml` already bakes in the fixed Developer ID signing identity for the Release
config, so no `CODE_SIGN_STYLE`/`DEVELOPMENT_TEAM` override is needed (Sparkle requires old and
new to be signed by the same team, and they are, automatically).

Pick `CURRENT_PROJECT_VERSION` values comfortably above `git rev-list --count HEAD` (currently in
the 600s, growing with every commit on `main`) — a leftover test install must not outrank the
next *real* release's build number, or it would refuse to accept it.

**Never open either of these locally built Release apps on a machine whose `~/.iris` you care
about before your first real install** — opening a build reporting `com.bnaylor.iris` spends the
one-time settings import from the dev home exactly like the real installed app would. Run this on
a test account, or only after the real install has already happened.

Install the older build (`/tmp/iris-updatetest-old/Build/Products/Release/Iris.app`) to
`/Applications`. DMG the newer one and sign it:

```sh
mkdir /tmp/iris-updatetest-dmg
ditto /tmp/iris-updatetest-new/Build/Products/Release/Iris.app /tmp/iris-updatetest-dmg/Iris.app
hdiutil create -volname "Iris 1.0.1" -srcfolder /tmp/iris-updatetest-dmg -ov -format UDZO \
  /tmp/Iris-1.0.1-test.dmg
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/sign_update --account iris /tmp/Iris-1.0.1-test.dmg
```

`sign_update` prints `sparkle:edSignature="…" length="…"`. Serve a directory containing the DMG
and an `appcast.xml` whose `<enclosure>` carries those attributes and points at the local server:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Iris Changelog (local test)</title>
    <item>
      <title>Version 1.0.1</title>
      <sparkle:version>900001</sparkle:version>
      <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="http://localhost:8000/Iris-1.0.1-test.dmg" type="application/octet-stream"
                 sparkle:edSignature="…" length="…"/>
    </item>
  </channel>
</rss>
```

```sh
cd /tmp/iris-updatetest-serve   # holds Iris-1.0.1-test.dmg and appcast.xml
python3 -m http.server 8000
```

Sparkle honours a user-defaults `SUFeedURL` override: `SPUUpdater` reads the feed URL through
`SUHost.objectForKey:ofClass:`, which checks `NSUserDefaults.standardUserDefaults` (keyed by the
running bundle's own identifier, since Iris sets no `SUDefaultsDomainKey`) before falling back to
the `Info.plist` value (confirmed by reading `SUHost.m`/`SPUUpdater.m` in the Sparkle checkout
under `.build/checkouts/Sparkle`). Point the installed test build at the local feed, launch it,
and check for updates:

```sh
defaults write com.bnaylor.iris SUFeedURL http://localhost:8000/appcast.xml
open /Applications/Iris.app
# Iris > Check for Updates…
```

Clean up afterwards:

```sh
defaults delete com.bnaylor.iris SUFeedURL
rm -rf /Applications/Iris.app   # the test install; its inflated build number must not linger
```
