import Foundation

enum PerfCommand: Equatable {
    case run(suite: String, reps: Int?, out: String, fakeOnly: Bool)
    case report(path: String)
    case compare(baseline: String, current: String, threshold: Double)
}

enum PerfCLIError: Error, Equatable, LocalizedError {
    case usage(String)
    var errorDescription: String? { if case .usage(let m) = self { return m } ; return nil }
}

/// `iris --perf run|report|compare`. Parsed before SwiftUI starts (see main.swift).
enum PerfCLI {
    static let usage = """
    usage:
      iris --perf run     <suite.json> [--reps N] [--out DIR] [--fake-only]
      iris --perf report  <run.json>
      iris --perf compare <baseline.json> <run.json> [--threshold 0.20]
    """

    static func parse(_ args: [String]) -> Result<PerfCommand, PerfCLIError>? {
        guard let i = args.firstIndex(of: "--perf") else { return nil }
        var rest = Array(args[(i + 1)...])
        guard !rest.isEmpty else { return .failure(.usage("missing subcommand")) }
        let sub = rest.removeFirst()
        func flag(_ name: String) -> Bool {
            if let j = rest.firstIndex(of: name) { rest.remove(at: j); return true }
            return false
        }
        func value(_ name: String) -> String?? {   // .some(nil) means flag present without value
            guard let j = rest.firstIndex(of: name) else { return nil }
            rest.remove(at: j)
            guard j < rest.count, !rest[j].hasPrefix("--") else { return .some(nil) }
            return .some(rest.remove(at: j))
        }
        switch sub {
        case "run":
            let fakeOnly = flag("--fake-only")
            var reps: Int?
            if let v = value("--reps") {
                guard let s = v, let n = Int(s) else { return .failure(.usage("--reps needs an integer")) }
                reps = n
            }
            var out = "perf/runs"
            if let v = value("--out") {
                guard let s = v else { return .failure(.usage("--out needs a directory")) }
                out = s
            }
            guard let suite = rest.first, !suite.hasPrefix("--") else { return .failure(.usage("run needs a suite path")) }
            if rest.count > 1 { return .failure(.usage("unexpected argument \(rest[1])")) }
            return .success(.run(suite: suite, reps: reps, out: out, fakeOnly: fakeOnly))
        case "report":
            guard let path = rest.first else { return .failure(.usage("report needs a run record path")) }
            if rest.count > 1 { return .failure(.usage("unexpected argument \(rest[1])")) }
            return .success(.report(path: path))
        case "compare":
            var threshold = 0.2
            if let v = value("--threshold") {
                guard let s = v, let t = Double(s) else { return .failure(.usage("--threshold needs a number")) }
                threshold = t
            }
            guard rest.count >= 2 else { return .failure(.usage("compare needs a baseline and a current record")) }
            if rest.count > 2 { return .failure(.usage("unexpected argument \(rest[2])")) }
            return .success(.compare(baseline: rest[0], current: rest[1], threshold: threshold))
        default:
            return .failure(.usage("unknown subcommand \(sub)"))
        }
    }

    /// A fresh, empty directory for a real-lane run's cwd and workspace, so file tools the model
    /// calls unattended (only run_command is sandboxed) land here and not in the repo (#151).
    static func makeScratchWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.standardizedFileURL
            .appendingPathComponent("iris-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// True when a real-lane run can skip the Keychain entirely: Gemini over ADC is the only
    /// configuration whose credentials live outside it.
    static func shouldBypassKeychain(provider: String?, geminiAuthMode: String?) -> Bool {
        provider == "Gemini" && geminiAuthMode == GeminiAuthMode.adc.rawValue
    }

    @MainActor
    static func execute(_ cmd: PerfCommand) async -> Int32 {
        do {
            switch cmd {
            case .run(let suitePath, let reps, let out, let fakeOnly):
                let suite = try PerfSuite.load(at: suitePath)
                if fakeOnly, suite.lane == .real {
                    print("perf: skipping real-lane suite \(suite.name) (--fake-only)")
                    return 0
                }
                // Settings come from a volatile copy so guard toggles never persist. Must precede
                // the first touch of ConfigManager.shared (inside the runner).
                IrisDefaults.useVolatileCopyOfStandard()
                if suite.lane == .fake {
                    HeadlessMode.enable()
                } else {
                    // A rebuilt binary prompts for Keychain access on its first secret read, which
                    // blocks an unattended run. Skip the Keychain when the provider never needs it.
                    let provider = IrisDefaults.store.string(forKey: "PRIMARY_PROVIDER") ?? "Gemini"
                    let authMode = IrisDefaults.store.string(forKey: "GEMINI_AUTH_MODE") ?? GeminiAuthMode.apiKey.rawValue
                    if shouldBypassKeychain(provider: provider, geminiAuthMode: authMode) {
                        KeychainManager.requestHeadlessBypass()
                    } else {
                        print("perf: provider secrets come from the Keychain; a rebuilt binary prompts once before the run can start")
                    }
                }
                let root = PerfPaths.repoRoot()   // before any cwd change
                let previousCwd = FileManager.default.currentDirectoryPath
                var scratch: URL?
                var memoryBefore: String?
                let realMemory = IrisPaths.default.memoryDir   // the real home, before any override
                if suite.lane == .real {
                    let dir = try makeScratchWorkspace()
                    FileManager.default.changeCurrentDirectoryPath(dir.path)
                    // Memory tools write through IrisPaths.default: route the whole home at a
                    // copy under the scratch directory so USER.md, the fact store and skills
                    // stay untouched. Reads see the same context.
                    try IrisPaths.useVolatileCopy(at: dir.appendingPathComponent(".iris"))
                    memoryBefore = IrisPaths.fingerprint(of: realMemory)
                    print("perf: real-lane file tools, cwd and ~/.iris confined to \(dir.path)")
                    scratch = dir
                }
                defer {
                    // Restore the cwd before deleting the directory it pointed at, so nothing that
                    // runs after this (today: exit) inherits a dangling working directory.
                    if let scratch {
                        FileManager.default.changeCurrentDirectoryPath(previousCwd)
                        try? FileManager.default.removeItem(at: scratch)
                    }
                }
                let record = try await PerfRunner.run(suite: suite, repetitionsOverride: reps, repoRoot: root,
                                                      headless: suite.lane == .fake, workspacePath: scratch?.path)
                print(PerfReport.render(record))
                let dir = out.hasPrefix("/") ? URL(fileURLWithPath: out) : root.appendingPathComponent(out)
                let url = try record.write(toDirectory: dir)
                print("perf: wrote \(url.path)")
                if let before = memoryBefore, IrisPaths.fingerprint(of: realMemory) != before {
                    print("perf: WARNING the real \(realMemory.path) changed during the run; something wrote outside the volatile copy")
                    return 3
                }
                return 0
            case .report(let path):
                print(PerfReport.render(try PerfRunRecord.load(at: path)))
                return 0
            case .compare(let a, let b, let threshold):
                let c = PerfCompare.compare(baseline: try PerfRunRecord.load(at: a), current: try PerfRunRecord.load(at: b), threshold: threshold)
                print(PerfCompare.render(c, threshold: threshold))
                return PerfCompare.exitCode(c)
            }
        } catch {
            FileHandle.standardError.write(Data("iris --perf: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
