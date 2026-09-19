import Testing
import Foundation
@testable import iris

@Suite("PerfRunRecord")
struct PerfRecordTests {
    static func sampleRecord() -> PerfRunRecord {
        let env = PerfEnvironment(gitSha: "abc1234", gitDirty: false, machineModel: "Mac16,7", osVersion: "26.0",
                                  cpuCount: 12, buildConfiguration: "release", provider: "Gemini",
                                  models: ["medium": "gemini-3.8-flash"], vibecopEnabled: true, vibecopEngine: "cloud",
                                  injectionGuardEnabled: true, promptGuardEngine: "cloud", sandboxEnabled: true,
                                  headless: false, toolDeclarationCount: 14)
        let call = ModelCallRecord(round: 0, model: "gemini-3.8-flash", latencyMs: 800, promptTokens: 3000, outputTokens: 40, returnedToolCalls: false)
        let turn = PerfTurn(totalMs: 850, categories: ["primaryLLM": CategoryStat(ms: 800, count: 1)], spans: ["guard.tier1": CategoryStat(ms: 1, count: 2)],
                            modelCalls: [call], toolCalls: [], finalTextLength: 120)
        let rep = PerfRepetition(index: 0, coldStart: true, wallClockMs: 860, turns: [turn], modelCalls: [], error: nil)
        let rung = PerfRungResult(rung: 5, repetitions: [rep], medianMs: 860, p90Ms: 860)
        let summary = PerfScenarioSummary(medianMs: 860, p90Ms: 860, overheadRatio: nil, harnessRatio: nil, toolCallRate: 0, toolCallsByName: [:])
        let scenario = PerfScenarioResult(name: "capital-city", path: "perf/prompts/model-only/capital-city.json", category: "model-only",
                                          lane: "real", rungs: [rung], summary: summary)
        return PerfRunRecord(schemaVersion: 1, suite: "ladder", startedAt: Date(timeIntervalSince1970: 1_000), finishedAt: Date(timeIntervalSince1970: 1_060),
                             environment: env, scenarios: [scenario])
    }

    @Test("round-trips through JSON")
    func roundTrip() throws {
        let record = Self.sampleRecord()
        let decoded = try PerfRunRecord.decode(from: record.encoded())
        #expect(decoded.suite == "ladder")
        #expect(decoded.scenarios.first?.rungs.first?.repetitions.first?.turns.first?.modelCalls.first?.promptTokens == 3000)
        #expect(decoded.environment.toolDeclarationCount == 14)
        #expect(decoded.startedAt == record.startedAt)
    }

    @Test("a record missing optional fields still decodes")
    func tolerantDecode() throws {
        let json = """
        {"schemaVersion":1,"suite":"s","startedAt":"2026-09-17T10:00:00Z","finishedAt":"2026-09-17T10:01:00Z",
         "environment":{"gitSha":"x","gitDirty":false,"machineModel":"m","osVersion":"o","cpuCount":1,"buildConfiguration":"debug",
           "provider":"Gemini","models":{},"vibecopEnabled":false,"vibecopEngine":"cloud","injectionGuardEnabled":false,
           "promptGuardEngine":"cloud","sandboxEnabled":false,"headless":true},
         "scenarios":[{"name":"n","path":"p","category":"c","lane":"fake","rungs":[],
           "summary":{"medianMs":0,"p90Ms":0,"toolCallRate":0,"toolCallsByName":{}}}]}
        """
        let record = try PerfRunRecord.decode(from: Data(json.utf8))
        #expect(record.environment.toolDeclarationCount == nil)
        #expect(record.scenarios.first?.summary.overheadRatio == nil)
    }

    @Test("file name is timestamp, suite and sha")
    func fileName() {
        #expect(Self.sampleRecord().fileName == "19700101T001640Z-ladder-abc1234.json")
    }

    @Test("write creates the directory and the file")
    func writeCreatesFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)/runs")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let url = try Self.sampleRecord().write(toDirectory: dir)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try PerfRunRecord.load(at: url.path).suite == "ladder")
    }

    @Test("PerfTurn is built from a CommandProfile")
    func fromProfile() {
        var profile = CommandProfile(id: UUID(), label: "l", source: "s", startedAt: Date())
        profile.totalMs = 12
        profile.add(.primaryLLM, durationMs: 10)
        profile.addSpan("guard.tier1", durationMs: 1)
        profile.toolCalls.append(ToolCallRecord(name: "read_file", ms: 2, ok: true))
        let turn = PerfTurn(profile, finalTextLength: 5)
        #expect(turn.totalMs == 12)
        #expect(turn.categories["primaryLLM"]?.ms == 10)
        #expect(turn.spans["guard.tier1"]?.count == 1)
        #expect(turn.toolCalls.first?.name == "read_file")
        #expect(turn.finalTextLength == 5)
    }

    @Test("file name sanitizes the suite name so it cannot escape the runs directory")
    func fileNameSanitized() {
        var r = Self.sampleRecord()
        r.suite = "../evil/suite name"
        #expect(r.fileName == "19700101T001640Z-..-evil-suite-name-abc1234.json" || !r.fileName.contains("/"))
        #expect(!r.fileName.contains("/"))
        #expect(!r.fileName.contains(" "))
    }

    @Test("a second write in the same second gets a numbered suffix instead of overwriting")
    func writeDoesNotOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try Self.sampleRecord().write(toDirectory: dir)
        let second = try Self.sampleRecord().write(toDirectory: dir)
        #expect(first != second)
        #expect(second.lastPathComponent == "19700101T001640Z-ladder-abc1234-2.json")
        #expect(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path))
    }

    @Test("a record from a newer schema is rejected with a clear error")
    func newerSchemaRejected() throws {
        var r = Self.sampleRecord()
        r.schemaVersion = PerfRunRecord.currentSchemaVersion + 1
        let data = try r.encoded()
        #expect(throws: PerfRecordError.self) { try PerfRunRecord.decode(from: data) }
    }

    @Test("a model call record without firstTokenMs decodes with nil; one with it round-trips")
    func firstTokenMsOptional() throws {
        let legacy = Data(#"{"round":0,"model":"m","latencyMs":10,"returnedToolCalls":false}"#.utf8)
        let decoded = try JSONDecoder().decode(ModelCallRecord.self, from: legacy)
        #expect(decoded.firstTokenMs == nil)
        let rec = ModelCallRecord(round: 1, model: "m", latencyMs: 20, promptTokens: nil, outputTokens: nil, returnedToolCalls: false, firstTokenMs: 3.5)
        let round = try JSONDecoder().decode(ModelCallRecord.self, from: JSONEncoder().encode(rec))
        #expect(round.firstTokenMs == 3.5)
    }

    @Test("PerfTurn keeps a capped, redacted copy of the final reply (#133 slice 2 diagnosis)")
    func finalTextKept() {
        var profile = CommandProfile(id: UUID(), label: "l", source: "s", startedAt: Date())
        profile.totalMs = 1
        let long = String(repeating: "x", count: 2000)
        let turn = PerfTurn(profile, finalText: long)
        #expect(turn.finalTextLength == 2000)
        #expect((turn.finalText?.count ?? 0) <= PerfTurn.finalTextLimit + 40)
        #expect(turn.finalText?.contains("truncated") == true)
        let secret = PerfTurn(profile, finalText: "your key is sk-abcdefghijklmnopqrstuvwxyz0123456789 ok")
        #expect(secret.finalText?.contains("sk-abc") == false)
        #expect(secret.finalText?.contains("[redacted]") == true)
        #expect(PerfTurn(profile, finalTextLength: 3).finalText == nil, "the older initializer still works")
    }
}
