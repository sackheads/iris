import Testing
import Foundation
@testable import IrisKit

@Suite("Bench CLI parsing and summary")
struct BenchCLITests {

    @Test("parse returns nil when --bench is absent")
    func parseNoBench() {
        #expect(BenchCLI.parse(["iris"]) == nil)
    }

    @Test("parse reads a scenario path after --bench")
    func parsePath() {
        let opts = BenchCLI.parse(["iris", "--bench", "foo.json"])
        #expect(opts?.scenarioPath == "foo.json")
        #expect(opts?.real == false)
    }

    @Test("parse treats --real as a flag, not a path")
    func parseRealFlag() {
        let opts = BenchCLI.parse(["iris", "--bench", "--real"])
        #expect(opts?.scenarioPath == nil)
        #expect(opts?.real == true)
    }

    @Test("parse reads both a path and --real")
    func parsePathAndReal() {
        let opts = BenchCLI.parse(["iris", "--bench", "foo.json", "--real"])
        #expect(opts?.scenarioPath == "foo.json")
        #expect(opts?.real == true)
    }

    @Test("built-in default scenario is a fake run with at least one turn")
    func defaultScenario() {
        let scenario = BenchCLI.defaultScenario
        #expect(scenario.clientMode == .fake)
        #expect(!scenario.turns.isEmpty)
        #expect(!scenario.scriptedResponses.isEmpty)
    }

    @Test("summary renders category rows, total, and wall-clock")
    func summaryRenders() {
        var profile = CommandProfile(id: UUID(), label: "echo", source: "User", startedAt: Date())
        profile.totalMs = 1000
        profile.add(.primaryLLM, durationMs: 600)
        profile.add(.toolExecution, durationMs: 300)
        let result = ScenarioResult(turnProfiles: [profile], wallClockMs: 1234.5,
                                    finalTexts: [], guardsWereOff: false, vibecopMeasured: false, toolsSandboxed: false, conversationId: UUID(), turnErrors: [])

        let text = BenchSummary.render(scenarioName: "echo", result: result)
        #expect(text.contains("echo"))
        #expect(text.contains(PerfCategory.primaryLLM.displayName))
        #expect(text.contains(PerfCategory.toolExecution.displayName))
        #expect(text.contains("1234")) // wall-clock ms appears
    }

    @Test("--dump-requests takes a directory and its value is not taken for the scenario path")
    func parseDumpRequests() {
        let a = BenchCLI.parse(["iris", "--bench", "--dump-requests", "out", "foo.json", "--transcript"])
        #expect(a?.scenarioPath == "foo.json")
        #expect(a?.dumpRequestsDir == "out")
        #expect(a?.transcript == true)
        let b = BenchCLI.parse(["iris", "--bench", "foo.json"])
        #expect(b?.dumpRequestsDir == nil)
        #expect(BenchCLI.parse(["iris", "--bench", "--grant-read", "w", "foo.json"])?.grant == .readOnly("w"))
        // A grant makes a mutating job, so it is refused with a real model, whether --real or the file says so.
        var scenario = BenchCLI.defaultScenario
        let granted = BenchCLI.parse(["iris", "--bench", "--grant-read", "w", "foo.json"])!
        #expect(BenchCLI.parse(["iris", "--bench", "--grant-write", "w", "foo.json"])?.grant == .readWrite("w"))
        #expect(BenchCLI.parse(["iris", "--bench", "--mutating-no-grant", "foo.json"])?.grant == BenchGrant.none)
        #expect(BenchCLI.parse(["iris", "--bench", "--mutating-no-grant", "foo.json"])?.scenarioPath == "foo.json")
        #expect(BenchCLI.refusal(granted, scenario: scenario) == nil)
        scenario.clientMode = .real
        #expect(BenchCLI.refusal(granted, scenario: scenario) != nil, "a real-mode scenario file")
        let plain = BenchCLI.parse(["iris", "--bench", "foo.json"])!
        #expect(BenchCLI.refusal(plain, scenario: scenario) == nil, "no grant, no refusal")
    }

    @Test("a background scenario's refused call reaches the transcript, and the requests are dumped")
    @MainActor
    func transcriptAndDumpShowADeniedCall() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bench-dump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scenario = Scenario(
            name: "denied", clientMode: .fake, tier: .medium,
            turns: [Scenario.Turn(prompt: "go")],
            scriptedResponses: [
                Scenario.ScriptedResponse(kind: .toolCalls, text: nil, calls: [
                    Scenario.ScriptedCall(name: "run_command", args: ["command": .string("echo bench-denied")])]),
                Scenario.ScriptedResponse(kind: .text, text: "Done.", calls: nil)],
            background: true)
        let result = await BenchCLI.runScenario(scenario, dumpRequestsTo: dir)
        let rendered = BenchSummary.renderTranscript(result)
        let notice = String(format: AppState.profileDenialNotice, "run_command")
        #expect(rendered.contains("Transcript, turn 1:"))
        #expect(rendered.contains(notice), "the read-only job's refusal is readable in the transcript")
        let dumped = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(dumped.contains("1-0.json"))
    }

    @Test("a granted directory's file is read by a background scenario, its text reaches the next request, and an ungranted one is refused")
    @MainActor
    func grantedReadReachesTheModel() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bench-ws-\(UUID().uuidString)")
        let ws = base.appendingPathComponent("ws"), dump = base.appendingPathComponent("dump")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = ws.appendingPathComponent("note.txt")
        try "PLANTED-807-MARKER".write(to: file, atomically: true, encoding: .utf8)
        let scenario = Scenario(
            name: "ws-read", clientMode: .fake, tier: .medium,
            turns: [Scenario.Turn(prompt: "go")],
            scriptedResponses: [
                Scenario.ScriptedResponse(kind: .toolCalls, text: nil, calls: [
                    Scenario.ScriptedCall(name: "read_file", args: ["path": .string(file.path)])]),
                Scenario.ScriptedResponse(kind: .text, text: "Done.", calls: nil)],
            background: true)
        let result = await BenchCLI.runScenario(scenario, dumpRequestsTo: dump, grant: .readOnly(ws.path))
        let rendered = BenchSummary.renderTranscript(result)
        #expect(!rendered.contains("needs approval"), "a granted read is not an unattended approval: \(rendered)")
        let next = try String(contentsOf: dump.appendingPathComponent("1-1.json"), encoding: .utf8)
        #expect(next.contains("PLANTED-807-MARKER"), "the file's text is in the request after the read")

        // The same read with no grant is refused, and the text never reaches the model.
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("bench-nogrant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bare) }
        let refused = await BenchCLI.runScenario(scenario, dumpRequestsTo: bare)
        #expect(BenchSummary.renderTranscript(refused).contains("needs approval"))
        let after = (try? String(contentsOf: bare.appendingPathComponent("1-1.json"), encoding: .utf8)) ?? ""
        #expect(!after.contains("PLANTED-807-MARKER"))
    }

    /// One scripted `write_file` in a background scenario, the whole call in its own scenario (a denied call ends the turn).
    private func writeOnce(to path: String, grant: BenchGrant) async -> (wrote: Bool, transcript: String) {
        let scenario = Scenario(
            name: "write", clientMode: .fake, tier: .medium,
            turns: [Scenario.Turn(prompt: "go")],
            scriptedResponses: [
                Scenario.ScriptedResponse(kind: .toolCalls, text: nil, calls: [
                    Scenario.ScriptedCall(name: "write_file", args: ["path": .string(path), "content": .string("bench-853")])]),
                Scenario.ScriptedResponse(kind: .text, text: "Done.", calls: nil)],
            background: true)
        let result = await BenchCLI.runScenario(scenario, grant: grant)
        return (FileManager.default.fileExists(atPath: path), BenchSummary.renderTranscript(result))
    }

    @Test("a read-write grant lets a background write_file land inside the mount and refuses one outside it; no grant refuses both")
    @MainActor
    func readWriteGrantAndNoGrant() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bench-rw-\(UUID().uuidString)")
        let mount = base.appendingPathComponent("mount"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let inside = await writeOnce(to: mount.appendingPathComponent("a.txt").path, grant: .readWrite(mount.path))
        #expect(inside.wrote, "inside a read-write mount the write is allowed unattended: \(inside.transcript)")

        let beyond = await writeOnce(to: outside.appendingPathComponent("b.txt").path, grant: .readWrite(mount.path))
        #expect(!beyond.wrote && beyond.transcript.contains("outside the grant"), "outside the mount it is refused: \(beyond.transcript)")

        let readOnly = await writeOnce(to: mount.appendingPathComponent("c.txt").path, grant: .readOnly(mount.path))
        #expect(!readOnly.wrote, "a read-only mount is not written: \(readOnly.transcript)")

        let bare = await writeOnce(to: outside.appendingPathComponent("d.txt").path, grant: .none)
        #expect(!bare.wrote, "a mutating job with no grant cannot write: \(bare.transcript)")
    }
}
