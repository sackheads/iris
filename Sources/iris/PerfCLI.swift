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
            return .success(.run(suite: suite, reps: reps, out: out, fakeOnly: fakeOnly))
        case "report":
            guard let path = rest.first else { return .failure(.usage("report needs a run record path")) }
            return .success(.report(path: path))
        case "compare":
            var threshold = 0.2
            if let v = value("--threshold") {
                guard let s = v, let t = Double(s) else { return .failure(.usage("--threshold needs a number")) }
                threshold = t
            }
            guard rest.count >= 2 else { return .failure(.usage("compare needs a baseline and a current record")) }
            return .success(.compare(baseline: rest[0], current: rest[1], threshold: threshold))
        default:
            return .failure(.usage("unknown subcommand \(sub)"))
        }
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
                if suite.lane == .fake { HeadlessMode.enable() }
                let root = PerfPaths.repoRoot()
                let record = try await PerfRunner.run(suite: suite, repetitionsOverride: reps, repoRoot: root, headless: suite.lane == .fake)
                print(PerfReport.render(record))
                let dir = out.hasPrefix("/") ? URL(fileURLWithPath: out) : root.appendingPathComponent(out)
                let url = try record.write(toDirectory: dir)
                print("perf: wrote \(url.path)")
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
