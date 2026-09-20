# Report: #210 — tier-2 prompt guard must not silently pass content when its CoreML model is absent

## Status: DONE (fix round 1 applied)

## Fix round 1 (commit 9896d05)

Reviewer findings addressed:

1. **No test exercised the changed guard lines.** `CoreMLEvaluator.setModel` now takes
   `CoreMLModelProtocol?` (source-compatible with all six existing callers), giving tests a way to
   force `hasModelLoaded` back to `false`. Added three dynamic tests in `InjectionGuardTests.swift`
   mirroring the tier-3 twins: `testTier2SkippedFallsThroughToTier3`,
   `testTier2SkippedVerdictDoesNotOutliveProvisioning`, and `testTier2BrokenModelFailsClosed` — the
   last one covers the do/catch → `.error` path **without** a bigger seam: the provisioning check
   is driven by a seam temp dir reporting `.provisioned`, while `CoreMLEvaluator.loadModelIfNeeded()`
   always resolves against the real `IrisPaths.default.modelsDir`, which under `swift test` never
   has this directory (`IrisDefaults` deliberately points `promptGuardCoreMLModel` at a name that
   cannot exist there) — so the real load throws exactly as a present-but-corrupted model would.
   Deleted `testTier2StubPassThrough` (duplicated `testTier2Safe`, named the removed behavior).
2. **`ModelDownloader`'s unzip never checked `terminationStatus`.** Fixed: checks the exit status,
   removes whatever a partial/failed extraction left at the resolved path, throws into the existing
   download-failure surface. No seam exists to unit-test the `URLSessionDownloadDelegate` callback
   itself (would need a URLSession abstraction) — noted, not added.
3. **De-duplication finished.** `SettingsView`/`SetupWizardView`'s hand-rolled URL+`.zip`
   resolution routed through new `ModelDownloader.isCoreMLModelDownloaded(name:)`, which also
   guards the empty-name case (the Wizard previously showed "Model ready" for a blank Tier 2 field,
   since `isModelDownloaded(name: "")` tested `modelsDir.path` itself).
4. **Minor cleanup**, all done: `ModelLED` takes an explicit `tierNumber: Int?` instead of deriving
   it from the label string; the shared `.unprovisioned` color comment no longer says only "tier
   3"; `cacheKey` takes `tier2ModelsDir` alongside `tier3ModelsDir`. Not done, noted instead: a
   `tier2State()` "ready"/"configured" positive-path test — unlike tier 3 (which has an
   engine-agnostic `"ollama"` bypass), tier 2 always checks the real `IrisPaths.default.modelsDir`
   with no injectable seam, so exercising that branch would require writing under
   `~/.iris/models`.

Verification: full suite 967 tests / 175 suites passed (Swift Testing) + all XCTest suites (96
tests, 0 failures), exit code 0. Isolated `swift test --filter EngineInstrumentationTests`: 5
tests / 1 suite passed, exit code 0.

## Original submission

### Status: DONE

## What changed

Mirrors PR #211 (f418120)'s fix for tier 3, applied to tier 2 (`InjectionGuard.executeTier2CoreML` /
`CoreMLEvaluator`):

- **`InjectionGuard.Tier2Provisioning`** (`.provisioned` / `.unprovisioned(modelName:)` /
  `.notConfigured`) and the pure predicate `tier2Provisioning(modelName:modelsDir:)`. An empty
  `promptGuardCoreMLModel` is `.notConfigured`; otherwise resolves the config value (URL →
  filename, strip `.zip`) via the new `ModelDownloader.resolvedCoreMLDirectoryName(for:)` sibling
  and checks the directory exists in `modelsDir`. `CoreMLEvaluator.loadModelIfNeeded()` and
  `ModelLEDBar.tier2State()` now both go through this same helper, so none of the three can drift.
- **Absent/unconfigured → skip, not silently pass.** `executeTier2CoreML` checks
  `CoreMLEvaluator.shared.hasModelLoaded` first (mirrors `hasEngine(for: "canary")` — an
  already-loaded evaluator, real or test mock, counts as provisioned regardless of the
  filesystem); if not loaded and the predicate says unprovisioned/notConfigured, it returns
  `.skipped` (logged once per process) instead of ever reaching `CoreMLEvaluator.evaluate`'s old
  silent 0.0 fallback.
- **Present but broken → fail closed.** `try?` on `loadModelIfNeeded()` replaced with `do/catch`
  returning `.error`; a load that returns without throwing but leaves `hasModelLoaded` false is
  also `.error`. Both exactly mirror the tier-3 canary's catch.
- **Cache.** `.skipped` is cached exactly like `.safe` (tier2 never had round-1's "never cache a
  skip" mistake to walk back — went straight to the final #202 design). `cacheKey` now takes both
  the resolved `Tier2Provisioning` and `Tier3Provisioning`; `sanitize` resolves both once up front
  and gained a `tier2ModelsDir` seam (mirrors `tier3ModelsDir`) alongside the existing one.
- **LED.** `ModelLEDBar.tier2State()` delegates to the predicate instead of duplicating the file
  check; `.notConfigured`/`.unprovisioned` both map to the existing `.unprovisioned` LED state.
  The shared `ModelLED` tooltip now says "tier 2" or "tier 3" based on the label (`P2`/`P3`)
  instead of hardcoding "tier 3".
- **Launch notice.** `tier3UnprovisionedNotice` replaced by
  `unprovisionedGuardNotice(protectionEnabled:tier2:tier3:)`, naming whichever tier(s) are missing
  in one sentence (singular wording for tier-3-only is byte-for-byte unchanged from #202).
  `AppState.init` gained `tier2Provisioning: InjectionGuard.Tier2Provisioning? = nil` beside
  `tier3Provisioning:`; both diffs are confined to the init signature and the launch-notice block.
- **Docs (invariant 9):** corrected the tier-2 "fail-closed" bullet and the verdict-cache
  description in `docs/prompt_injection_guard_design.md`, and a stale "no prompt-guard model can
  load → fails closed" claim in `docs/ipf/spec.md` (plugin `rules` component) that was wrong for
  both tiers, not just tier 2. Left `docs/specs/2026-07-15-library-core-design.md`'s historical
  tier-3 "Risks & Notes" alone, same as #211 did — it's a dated planning snapshot, not living
  documentation, and #211 didn't touch it either.

## Tests

- `Tests/irisTests/Tier2ProvisioningTests.swift` (new): predicate coverage — provisioned/absent,
  URL+`.zip` resolution, empty name → `.notConfigured`.
- `Tests/irisTests/Tier2ProvisioningTests.swift` `UnprovisionedGuardNoticeTests` (new): nil on
  protection-off and both-provisioned, singular tier-2-only, singular tier-3-only (byte-identical
  to the old #202 text), `.notConfigured` phrasing, plural both-missing.
- `Tests/irisTests/Tier3ProvisioningTests.swift`: removed the 3 tests that called the now-deleted
  `tier3UnprovisionedNotice`; predicate tests untouched.
- `Tests/irisTests/ConversationStoreSelectionTests.swift`: added
  `tier2UnprovisionedNoticeAppended`/`tier2UnprovisionedNoticeAbsentWhenProvisioned` (mirrors the
  tier-3 pair); every existing `AppState(..., tier3Provisioning:)` call site also now pins
  `tier2Provisioning: .provisioned`, per the brief.
- `Tests/irisTests/ModelLEDBarTests.swift`: **found and fixed two real regressions** the brief
  didn't flag — `testTier2ConfiguredWhenModelFieldEmpty`/`testTier2ConfiguredWhenModelNotDownloaded`
  asserted the old `.configured` LED state, which is now wrong (`.unprovisioned`). This is an
  XCTest-based file; its failures don't show up in the Swift Testing summary line ("N tests in M
  suites passed") that the rest of the suite reports through, only in the process exit code — I
  caught it only by explicitly checking exit codes and grepping for `error:` rather than trusting
  the tail of a truncated `swift test` run. Renamed and fixed both to expect `.unprovisioned`.

**Deliberately not covered** (documented in the new test file's suite doc comment): a dynamic
`sanitize()`-level test proving the tier-2 skip falls through to tier 3, and one proving cache
invalidation when tier-2 provisioning changes mid-process — tier 3's equivalents
(`testTier3SkippedWhenModelUnprovisioned`, `testSkippedVerdictDoesNotOutliveProvisioning`) rely on
`AuxiliaryModelManager.unloadEngine`, pre-existing production API with no tier-2 equivalent;
`CoreMLEvaluator` has `setModel` to *install* a fake but nothing to reset it, so once any test in
the process has called it (several already do), `hasModelLoaded` stays true for the rest of the
run and a later test cannot force the unprovisioned path. Per the brief's ruling, adding a
reset seam to `CoreMLEvaluator` is out of scope for this PR. The skip path (predicate, fully
covered above) and the verdict mapping (`.unprovisioned`/`.notConfigured` → `.skipped`, `.skipped`
cached like `.safe` — both in `executeTier2CoreML`/`sanitize`, structurally identical to tier 3's
already-tested handling) stand in for it.

## Verification

- Full suite: `swift test` → **965 tests in 175 suites passed** (Swift Testing) plus the XCTest
  suites (`ModelLEDBarTests` etc.) green; confirmed via explicit exit code (0), not just the
  Swift Testing summary line.
- Isolated: `swift test --filter EngineInstrumentationTests` → **5 tests in 1 suite passed**,
  exit code 0. `staticContextSanitizedOnce` already calls `CoreMLEvaluator.shared.setModel(...)`
  before running its scenario, which — same as before this change — makes tier 2 evaluate via the
  mock rather than skip, so it is unaffected by the new provisioning check.
- `swift build` clean.

## Commits

See `git log` on branch `fix/210-tier2-unprovisioned`.

## Concerns

- The ModelLEDBarTests miss above is a process note, not a residual risk: it's fixed and verified
  green now, but it's worth flagging that this repo's XCTest suites can fail silently past a
  truncated `tail` of `swift test` output — the Swift Testing summary line at the very end covers
  only Swift Testing tests, not the separate `irisPackageTests.xctest` XCTest run reported earlier
  in the same invocation.
- The two dynamic tests skipped per "cover the skip path... and say so" (see Tests section) are a
  real, if narrow, coverage gap: nothing exercises `executeTier2CoreML`'s unprovisioned→`.skipped`
  branch or the cache-key-changes-on-provisioning-change behavior end-to-end for tier 2 the way
  tier 3's tests do. The source logic is a structural mirror of tier 3's (already exercised) code,
  so risk is low, but a future `CoreMLEvaluator` reset/test-seam addition should pick this back up.
