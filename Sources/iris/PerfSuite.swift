import Foundation

enum PerfSuiteError: Error, Equatable, LocalizedError {
    case emptyScenarios
    case invalidRung(Int)
    case fakeLaneNeedsFullTurn([Int])
    case invalidRepetitions(Int)

    var errorDescription: String? {
        switch self {
        case .emptyScenarios: return "suite lists no scenarios"
        case .invalidRung(let r): return "rung \(r) is outside 1...5"
        case .fakeLaneNeedsFullTurn(let rs): return "fake lane cannot run rungs \(rs); only 4 and 5 are meaningful without a provider"
        case .invalidRepetitions(let n): return "repetitions must be >= 1, got \(n)"
        }
    }
}

/// A perf suite: which scenarios to run, in which lane, how many times, at which ladder rungs.
struct PerfSuite: Codable, Sendable {
    enum Lane: String, Codable, Sendable { case fake, real }

    var name: String
    var lane: Lane
    var repetitions: Int
    var pauseMs: Int
    var rungs: [Int]
    var scenarios: [String]

    init(name: String, lane: Lane = .fake, repetitions: Int = 3, pauseMs: Int = 0, rungs: [Int] = [5], scenarios: [String]) {
        self.name = name; self.lane = lane; self.repetitions = repetitions
        self.pauseMs = pauseMs; self.rungs = rungs; self.scenarios = scenarios
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        lane = try c.decodeIfPresent(Lane.self, forKey: .lane) ?? .fake
        repetitions = try c.decodeIfPresent(Int.self, forKey: .repetitions) ?? 3
        pauseMs = try c.decodeIfPresent(Int.self, forKey: .pauseMs) ?? 0
        rungs = try c.decodeIfPresent([Int].self, forKey: .rungs) ?? [5]
        scenarios = try c.decodeIfPresent([String].self, forKey: .scenarios) ?? []
    }

    func validate() throws {
        if scenarios.isEmpty { throw PerfSuiteError.emptyScenarios }
        if repetitions < 1 { throw PerfSuiteError.invalidRepetitions(repetitions) }
        if let bad = rungs.first(where: { !(1...5).contains($0) }) { throw PerfSuiteError.invalidRung(bad) }
        let ladderOnly = rungs.filter { $0 < 4 }
        if lane == .fake, !ladderOnly.isEmpty { throw PerfSuiteError.fakeLaneNeedsFullTurn(ladderOnly) }
    }

    static func decode(from data: Data) throws -> PerfSuite {
        let suite = try JSONDecoder().decode(PerfSuite.self, from: data)
        try suite.validate()
        return suite
    }

    static func load(at path: String) throws -> PerfSuite {
        try decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func scenarioURLs(relativeTo root: URL) -> [URL] {
        scenarios.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : root.appendingPathComponent($0) }
    }
}

enum PerfPaths {
    /// The directory holding this source file, captured at compile time.
    ///
    /// The repo root is resolved from here rather than from the process working directory: the
    /// working directory is process-global mutable state, `swift test` runs suites in parallel,
    /// and a suite that calls `changeCurrentDirectoryPath` used to make every perf suite
    /// intermittently resolve the root to `/` and fail on a fixture that was present all along
    /// (#242, and the second of the two flakes in #160).
    private static let sourceAnchor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    /// Walk up to the first directory holding Package.swift. `start` overrides the anchor.
    static func repoRoot(from start: URL? = nil) -> URL {
        if let start { return walkUp(from: start) }
        // Tests and the perf CLI both run from a checkout, so the source tree is present.
        let fromSource = walkUp(from: sourceAnchor)
        if FileManager.default.fileExists(atPath: fromSource.appendingPathComponent("Package.swift").path) {
            return fromSource
        }
        // A binary running without its sources beside it: the working directory is all we have.
        return walkUp(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    private static func walkUp(from start: URL) -> URL {
        var dir = start.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return start }
            dir = parent
        }
    }
}
