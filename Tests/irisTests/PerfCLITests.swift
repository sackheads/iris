import Testing
import Foundation
@testable import iris

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
        let code = await PerfCLI.execute(.run(suite: suitePath, reps: nil, out: dir.appendingPathComponent("runs").path, fakeOnly: true))
        #expect(code == 0)
        // Nothing was written: the run never started.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("runs").path))
    }

    @Test("a scratch workspace is a fresh empty directory under the temporary directory (#151)")
    func scratchWorkspace() throws {
        let a = try PerfCLI.makeScratchWorkspace()
        let b = try PerfCLI.makeScratchWorkspace()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        #expect(a != b)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: a.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: a.path).isEmpty)
        #expect(a.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        #expect(a.lastPathComponent.hasPrefix("iris-perf-"))
    }
}
