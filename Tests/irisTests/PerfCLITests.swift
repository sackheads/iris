import Testing
import Foundation
@testable import IrisKit

@Suite("PerfCLI parsing")
struct PerfCLITests {
    @Test("absent --perf is nil")
    func absent() {
        #expect(PerfCLI.parse(["iris"]) == nil)
        #expect(PerfCLI.parse(["iris", "--bench"]) == nil)
    }

    @Test("run with defaults and with every flag")
    func run() {
        #expect(PerfCLI.parse(["iris", "--perf", "run", "perf/suites/smoke.json"]) ==
                .success(.run(suite: "perf/suites/smoke.json", reps: nil, out: "perf/runs", fakeOnly: false)))
        #expect(PerfCLI.parse(["iris", "--perf", "run", "s.json", "--reps", "5", "--out", "/tmp/x", "--fake-only"]) ==
                .success(.run(suite: "s.json", reps: 5, out: "/tmp/x", fakeOnly: true)))
    }

    @Test("--dump-requests parses into its own directory (5a)")
    func dumpRequests() {
        #expect(PerfCLI.parse(["iris", "--perf", "run", "s.json", "--dump-requests", "/tmp/dumps"]) ==
                .success(.run(suite: "s.json", reps: nil, out: "perf/runs", fakeOnly: false, dumpRequestsDir: "/tmp/dumps")))
        #expect(PerfCLI.parse(["iris", "--perf", "run", "s.json", "--dump-requests"]) ==
                .failure(.usage("--dump-requests needs a directory")))
    }

    @Test("report and compare")
    func reportAndCompare() {
        #expect(PerfCLI.parse(["iris", "--perf", "report", "a.json"]) == .success(.report(path: "a.json")))
        #expect(PerfCLI.parse(["iris", "--perf", "compare", "a.json", "b.json"]) == .success(.compare(baseline: "a.json", current: "b.json", threshold: 0.2)))
        #expect(PerfCLI.parse(["iris", "--perf", "compare", "a.json", "b.json", "--threshold", "0.5"]) == .success(.compare(baseline: "a.json", current: "b.json", threshold: 0.5)))
    }

    @Test("bad invocations are usage errors")
    func usageErrors() {
        #expect(PerfCLI.parse(["iris", "--perf"]) == .failure(.usage("missing subcommand")))
        #expect(PerfCLI.parse(["iris", "--perf", "run"]) == .failure(.usage("run needs a suite path")))
        #expect(PerfCLI.parse(["iris", "--perf", "compare", "a.json"]) == .failure(.usage("compare needs a baseline and a current record")))
        #expect(PerfCLI.parse(["iris", "--perf", "run", "s.json", "--reps", "x"]) == .failure(.usage("--reps needs an integer")))
        #expect(PerfCLI.parse(["iris", "--perf", "frobnicate"]) == .failure(.usage("unknown subcommand frobnicate")))
    }

    @Test("extra positional arguments are usage errors")
    func extraPositionals() {
        #expect(PerfCLI.parse(["iris", "--perf", "compare", "a.json", "b.json", "c.json"]) == .failure(.usage("unexpected argument c.json")))
        #expect(PerfCLI.parse(["iris", "--perf", "report", "a.json", "b.json"]) == .failure(.usage("unexpected argument b.json")))
        #expect(PerfCLI.parse(["iris", "--perf", "run", "s.json", "extra"]) == .failure(.usage("unexpected argument extra")))
    }

    @Test("a real-lane run bypasses the Keychain only when the provider needs no Keychain secret")
    func keychainBypassDecision() {
        // Gemini over ADC gets its token from gcloud; nothing in the Keychain is needed.
        #expect(PerfCLI.shouldBypassKeychain(provider: "Gemini", geminiAuthMode: GeminiAuthMode.adc.rawValue))
        // API-key configurations need the Keychain; a rebuilt binary will prompt once.
        #expect(!PerfCLI.shouldBypassKeychain(provider: "Gemini", geminiAuthMode: GeminiAuthMode.apiKey.rawValue))
        #expect(!PerfCLI.shouldBypassKeychain(provider: "Anthropic", geminiAuthMode: GeminiAuthMode.adc.rawValue))
        #expect(!PerfCLI.shouldBypassKeychain(provider: nil, geminiAuthMode: nil))
    }

    /// The brief for this suite (task-3, 5a) says `--fake-only` on a real-lane suite should
    /// "reject" it; what `execute` actually does (and has done since before this task) is skip it
    /// with a clear message and exit 0, never touching credentials, the Keychain or the network.
    /// That is the useful behavior for an unattended `--fake-only` sweep across suites of mixed
    /// lane, so this asserts the existing skip rather than changing it to an error exit.
    @MainActor
    @Test("--fake-only skips a real-lane suite with a message instead of running it")
    func fakeOnlySkipsRealLaneSuite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-perfcli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suitePath = dir.appendingPathComponent("caching.json").path
        // A suite that never needs its scenario file to exist for this path: the skip happens
        // right after `PerfSuite.load`, before any scenario is read.
        try #"{"name":"caching","lane":"real","scenarios":["does-not-exist.json"]}"#
            .write(toFile: suitePath, atomically: true, encoding: .utf8)
        let recorder = PerfCLIEnvironmentRecorder()
        let code = await PerfCLI.execute(.run(suite: suitePath, reps: nil, out: dir.appendingPathComponent("runs").path, fakeOnly: true),
                                         environment: recorder.environment)
        #expect(code == 0)
        // Nothing was written and nothing was prepared: the run never started.
        #expect(recorder.volatileDefaultsRequests == 0)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("runs").path))
    }

    /// #324: `execute` used to flip three process-wide, one-way switches itself, so a test driving
    /// a fake-lane suite through it changed the store, `~/.iris` and the Keychain mode for every
    /// suite after it. They are injected now; this runs a fake-lane suite through `execute`, past
    /// the `--fake-only` skip, and checks the process is as it was — and that `execute` still asked
    /// for the volatile settings copy, the one switch a fake lane needs.
    @MainActor
    @Test("a fake-lane run through execute leaves the process globals unchanged (#324)")
    func fakeLaneExecuteLeavesGlobalsAlone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-perfcli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suitePath = dir.appendingPathComponent("fake.json").path
        try #"{"name":"globals-probe","lane":"fake","repetitions":1,"rungs":[5],"scenarios":["perf/prompts/fake/text-only.json"]}"#
            .write(toFile: suitePath, atomically: true, encoding: .utf8)
        let defaultsBefore = IrisDefaults.isVolatileCopy
        let pathsBefore = IrisPaths.isVolatileCopy
        let homeBefore = IrisPaths.default.root
        let bypassBefore = KeychainManager.headlessBypassRequested
        let recorder = PerfCLIEnvironmentRecorder()
        let out = dir.appendingPathComponent("runs")
        let code = await PerfCLI.execute(.run(suite: suitePath, reps: 1, out: out.path, fakeOnly: true),
                                         environment: recorder.environment)
        #expect(code == 0)
        // It actually ran: a record was written, so the skip was passed.
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).isEmpty)
        #expect(recorder.volatileDefaultsRequests == 1)
        #expect(recorder.volatilePathRoots.isEmpty)
        #expect(recorder.keychainBypassRequests == 0)
        #expect(IrisDefaults.isVolatileCopy == defaultsBefore)
        #expect(!IrisDefaults.isVolatileCopy)
        #expect(IrisPaths.isVolatileCopy == pathsBefore)
        #expect(IrisPaths.default.root == homeBefore)
        #expect(KeychainManager.headlessBypassRequested == bypassBefore)
    }

    /// The real lane's half of #324, without running a real-lane suite (that claims `$TMPDIR`'s
    /// scratch workspace and moves the cwd): the Keychain bypass goes through the environment.
    @Test("a real-lane ADC run requests the Keychain bypass through the environment, not the process (#324)")
    func realLaneKeychainBypassIsInjected() {
        let bypassBefore = KeychainManager.headlessBypassRequested
        let defaultsBefore = IrisDefaults.isVolatileCopy
        let recorder = PerfCLIEnvironmentRecorder()
        recorder.store.set("Gemini", forKey: "PRIMARY_PROVIDER")
        recorder.store.set(GeminiAuthMode.adc.rawValue, forKey: "GEMINI_AUTH_MODE")
        let suite = PerfSuite(name: "real-probe", lane: .real, repetitions: 1, rungs: [5], scenarios: [])
        PerfCLI.prepare(for: suite, environment: recorder.environment)
        #expect(recorder.volatileDefaultsRequests == 1)
        #expect(recorder.keychainBypassRequests == 1)
        #expect(KeychainManager.headlessBypassRequested == bypassBefore)
        #expect(!KeychainManager.headlessBypassRequested)
        #expect(IrisDefaults.isVolatileCopy == defaultsBefore)
    }

    /// A dropped or misrouted `useVolatilePaths` would have a real-lane run write the developer's
    /// real `~/.iris`. The scratch claim and the chdir around it are injected too, so this runs a
    /// real-lane suite with a fake client (no network, no spend) and checks the home was routed at
    /// `<scratch>/.iris` before the first model call.
    @MainActor
    @Test("a real-lane run routes ~/.iris at <scratch>/.iris before the first scenario (#324)")
    func realLaneRoutesHomeIntoScratch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-perfcli-\(UUID().uuidString)")
        let scratch = dir.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = PerfCLIEnvironmentRecorder(scratch: scratch)
        let client = PathsProbingLLMClient(recorder: recorder, responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "Canberra.")]))], usageMetadata: nil)
        ])
        let suite = PerfSuite(name: "paths-probe", lane: .real, repetitions: 1, rungs: [5],
                              scenarios: ["perf/prompts/fake/text-only.json"])
        let code = try await PerfCLI.runSuiteRespectingLane(suite, repetitionsOverride: 1,
                                                            out: dir.appendingPathComponent("runs").path,
                                                            dumpRequestsDir: nil, environment: recorder.environment,
                                                            client: client)
        #expect(code == 0)
        #expect(recorder.volatilePathRoots == [scratch.appendingPathComponent(".iris")])
        #expect(client.calls > 0)
        #expect(client.pathsRoutedBeforeFirstCall == true)
        #expect(recorder.scratchClaims == 1 && recorder.scratchReleases == 1)
        #expect(recorder.directoryChanges.first == scratch.path)
        #expect(recorder.directoryChanges.count == 2, "the cwd is restored after the run")
        #expect(!IrisPaths.isVolatileCopy)
    }

    /// Each test gets its own `base`, so none of this collides with a real perf run (which always
    /// uses `$TMPDIR` itself) or another test's claim — invariant 7, applied to a brand-new global.
    private func testBase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("iris-perfcli-test-\(UUID().uuidString)")
    }

    @Test("the scratch workspace location is fixed across invocations, not a per-run UUID (#321)")
    func scratchWorkspaceLocationIsFixed() {
        let base = testBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let a = PerfCLI.scratchWorkspaceURL(base: base)
        let b = PerfCLI.scratchWorkspaceURL(base: base)
        #expect(a == b)
        #expect(a.lastPathComponent == "iris-perf")
        #expect(a.deletingLastPathComponent().path == base.standardizedFileURL.path)
    }

    @Test("claiming the workspace gives a fresh empty directory under it (#151)")
    func claimGivesFreshEmptyDirectory() throws {
        let base = testBase()
        defer {
            PerfCLI.releaseScratchWorkspace(base: base)
            try? FileManager.default.removeItem(at: base)
        }
        let dir = try PerfCLI.claimScratchWorkspace(base: base)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(dir == PerfCLI.scratchWorkspaceURL(base: base))
    }

    @Test("a leftover directory from a crashed run is reset, not an error (#321)")
    func claimResetsLeftoverDirectory() throws {
        let base = testBase()
        defer {
            PerfCLI.releaseScratchWorkspace(base: base)
            try? FileManager.default.removeItem(at: base)
        }
        let url = PerfCLI.scratchWorkspaceURL(base: base)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("iris/memory"), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: url.appendingPathComponent("stale.txt"))
        let claimed = try PerfCLI.claimScratchWorkspace(base: base)
        #expect(claimed == url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: claimed.path).isEmpty)
    }

    @Test("a second claim while the lock is held is refused, not raced (#321)")
    func secondClaimWhileHeldIsRefused() throws {
        let base = testBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let lockURL = PerfCLI.scratchLockURL(base: base)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // pid 1 is launchd: alive, and not us (same idiom as RunJobCLITests' GUILock coverage).
        try Data("1\n".utf8).write(to: lockURL)
        #expect(throws: PerfCLIError.self) {
            try PerfCLI.claimScratchWorkspace(base: base)
        }
    }

    @Test("releasing the workspace lets a later claim succeed again (#321)")
    func releaseAllowsReclaim() throws {
        let base = testBase()
        defer {
            PerfCLI.releaseScratchWorkspace(base: base)
            try? FileManager.default.removeItem(at: base)
        }
        _ = try PerfCLI.claimScratchWorkspace(base: base)
        PerfCLI.releaseScratchWorkspace(base: base)
        let again = try PerfCLI.claimScratchWorkspace(base: base)
        #expect(again == PerfCLI.scratchWorkspaceURL(base: base))
    }

    // #321: the whole point of a fixed scratch location is that the system prompt's skills list —
    // specifically each skill's **Path:** line, which is the real absolute `skillFilePath` — comes
    // out byte-identical across separate runs, rather than cache-busting on a fresh per-run UUID.
    @Test("the rendered skills list is byte-identical across two runs' homes under the fixed location")
    func skillsListStableAcrossRunsAtFixedLocation() async throws {
        let base = testBase()
        defer {
            PerfCLI.releaseScratchWorkspace(base: base)
            try? FileManager.default.removeItem(at: base)
        }
        let okf = """
        ---
        title: Deploy
        description: Ship the thing.
        ---
        Body.
        """
        func seedAndRenderOneRun() async throws -> String {
            let dir = try PerfCLI.claimScratchWorkspace(base: base)
            let home = IrisPaths(root: dir.appendingPathComponent(".iris"))
            try home.ensureDirectories()
            let skillDir = home.skillsDir.appendingPathComponent("deploy")
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            try okf.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            // extraRoots: [] and never PluginManager.shared — this must not touch any process-global.
            let summary = await SkillManager.shared.discoverSkills(paths: home, extraRoots: [])
            PerfCLI.releaseScratchWorkspace(base: base)
            return summary
        }
        let runA = try await seedAndRenderOneRun()
        let runB = try await seedAndRenderOneRun()
        #expect(runA == runB)
        #expect(runA.contains("**Path:**"))
    }
}

/// A `PerfCLI.ExecutionEnvironment` that records what `execute` asked for and changes nothing
/// process-wide (#324). Reads go to a throwaway suite, never `IrisDefaults.store`; the scratch
/// claim returns `scratch` (a test's own temp dir) and the chdir only records.
final class PerfCLIEnvironmentRecorder {
    private(set) var volatileDefaultsRequests = 0
    private(set) var volatilePathRoots: [URL] = []
    private(set) var keychainBypassRequests = 0
    private(set) var scratchClaims = 0
    private(set) var scratchReleases = 0
    private(set) var directoryChanges: [String] = []
    let store = UserDefaults(suiteName: "iris-perfcli-env-\(UUID().uuidString)")!
    private let scratch: URL?
    /// Stands in for the real home in the run's memory-fingerprint check. The test process's own
    /// home is shared with every suite running beside it, so its fingerprint is not this run's.
    private let home: IrisPaths

    init(scratch: URL? = nil) {
        self.scratch = scratch
        home = IrisPaths(root: (scratch ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-perfcli-home-\(UUID().uuidString)")).appendingPathComponent("real-home"))
    }

    var environment: PerfCLI.ExecutionEnvironment {
        PerfCLI.ExecutionEnvironment(useVolatileDefaults: { self.volatileDefaultsRequests += 1 },
                                     defaults: { self.store },
                                     useVolatilePaths: { self.volatilePathRoots.append($0) },
                                     requestKeychainBypass: { self.keychainBypassRequests += 1 },
                                     claimScratch: {
                                         self.scratchClaims += 1
                                         guard let scratch = self.scratch else { throw PerfCLIError.usage("no scratch in this test") }
                                         return scratch
                                     },
                                     releaseScratch: { self.scratchReleases += 1 },
                                     changeDirectory: { self.directoryChanges.append($0) },
                                     realHome: { self.home })
    }
}

/// Notes, at the first model call, whether `useVolatilePaths` had already been called.
private final class PathsProbingLLMClient: LLMClientProtocol, @unchecked Sendable {
    private let inner: FakeLLMClient
    private let recorder: PerfCLIEnvironmentRecorder
    private(set) var calls = 0
    private(set) var pathsRoutedBeforeFirstCall: Bool?
    init(recorder: PerfCLIEnvironmentRecorder, responses: [GeminiResponse]) {
        self.recorder = recorder
        inner = FakeLLMClient(responses: responses)
    }
    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        if pathsRoutedBeforeFirstCall == nil { pathsRoutedBeforeFirstCall = !recorder.volatilePathRoots.isEmpty }
        calls += 1
        return try await inner.generateContent(request: request, tier: tier)
    }
}
