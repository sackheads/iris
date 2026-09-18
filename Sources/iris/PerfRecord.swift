import Foundation

enum PerfRecordError: Error, Equatable, LocalizedError {
    case newerSchema(found: Int, supported: Int)
    var errorDescription: String? {
        if case .newerSchema(let f, let s) = self { return "record schemaVersion \(f) is newer than this build supports (\(s)); update iris to read it" }
        return nil
    }
}

/// One perf suite run, persisted as JSON under perf/runs/ (and perf/baselines/ when promoted).
/// Every field added after schemaVersion 1 must be Optional so old records keep decoding.
struct PerfRunRecord: Codable {
    var schemaVersion: Int
    var suite: String
    var startedAt: Date
    var finishedAt: Date
    var environment: PerfEnvironment
    var scenarios: [PerfScenarioResult]

    static let currentSchemaVersion = 1

    private static let coder: (JSONEncoder, JSONDecoder) = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (e, d)
    }()

    static func decode(from data: Data) throws -> PerfRunRecord {
        // Peek the version first so a newer record fails with a reason instead of a field error.
        struct Header: Decodable { var schemaVersion: Int? }
        if let v = try? JSONDecoder().decode(Header.self, from: data).schemaVersion, v > currentSchemaVersion {
            throw PerfRecordError.newerSchema(found: v, supported: currentSchemaVersion)
        }
        return try coder.1.decode(PerfRunRecord.self, from: data)
    }

    static func load(at path: String) throws -> PerfRunRecord {
        try decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func encoded() throws -> Data { try Self.coder.0.encode(self) }

    /// `<yyyyMMdd'T'HHmmss'Z'>-<suite>-<sha>.json`, sortable by time.
    var fileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return "\(f.string(from: startedAt))-\(Self.fileSafe(suite))-\(Self.fileSafe(environment.gitSha)).json"
    }

    /// Suite names come from committed files, but the name is a path component: anything
    /// outside `[A-Za-z0-9._-]` becomes `-` so it can never escape the runs directory.
    static func fileSafe(_ s: String) -> String {
        String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") ? $0 : "-" })
    }

    @discardableResult
    func write(toDirectory dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Second resolution: a second run of the same suite in the same second gets -2, -3, ...
        var url = dir.appendingPathComponent(fileName)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(fileName.replacingOccurrences(of: ".json", with: "-\(n).json"))
            n += 1
        }
        try encoded().write(to: url, options: .atomic)
        return url
    }
}

struct PerfEnvironment: Codable {
    var gitSha: String
    var gitDirty: Bool
    var machineModel: String
    var osVersion: String
    var cpuCount: Int
    var buildConfiguration: String
    var provider: String
    var models: [String: String]
    var vibecopEnabled: Bool
    var vibecopEngine: String
    var injectionGuardEnabled: Bool
    var promptGuardEngine: String
    var sandboxEnabled: Bool
    var headless: Bool
    /// From the last scenario's captured request in the run; per-run because MCP configuration
    /// is per-process, not per scenario.
    var toolDeclarationCount: Int?
}

struct PerfScenarioResult: Codable {
    var name: String
    var path: String
    var category: String
    var lane: String
    var rungs: [PerfRungResult]
    var summary: PerfScenarioSummary
}

struct PerfRungResult: Codable {
    var rung: Int
    var repetitions: [PerfRepetition]
    var medianMs: Double
    var p90Ms: Double
}

struct PerfRepetition: Codable {
    var index: Int
    var coldStart: Bool
    var wallClockMs: Double
    var turns: [PerfTurn]
    var modelCalls: [ModelCallRecord]
    var error: String?
}

struct PerfTurn: Codable {
    var totalMs: Double
    var categories: [String: CategoryStat]
    var spans: [String: CategoryStat]
    var modelCalls: [ModelCallRecord]
    var toolCalls: [ToolCallRecord]
    var finalTextLength: Int

    init(totalMs: Double, categories: [String: CategoryStat], spans: [String: CategoryStat],
         modelCalls: [ModelCallRecord], toolCalls: [ToolCallRecord], finalTextLength: Int) {
        self.totalMs = totalMs; self.categories = categories; self.spans = spans
        self.modelCalls = modelCalls; self.toolCalls = toolCalls; self.finalTextLength = finalTextLength
    }

    init(_ profile: CommandProfile, finalTextLength: Int) {
        self.init(totalMs: profile.totalMs,
                  categories: Dictionary(uniqueKeysWithValues: profile.categories.map { ($0.key.rawValue, $0.value) }),
                  spans: profile.spans, modelCalls: profile.modelCalls, toolCalls: profile.toolCalls,
                  finalTextLength: finalTextLength)
    }
}

struct PerfScenarioSummary: Codable {
    var medianMs: Double
    var p90Ms: Double
    var overheadRatio: Double?
    var harnessRatio: Double?
    var toolCallRate: Double
    var toolCallsByName: [String: Int]
}
