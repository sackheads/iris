import Testing
import Foundation
@testable import IrisKit

/// #783's bake-off harness in `iris --guard-probe --fixtures`: its options, what it judges, and
/// that the cloud thinking level is the probe's alone.
@Suite("guard-probe fixtures mode (#783)", .timeLimit(.minutes(1)))
struct GuardProbeFixturesTests {
    private struct Canned: AuxiliaryInferenceEngine {
        let answer: @Sendable () throws -> String
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String { try answer() }
    }
    private struct Down: Error {}

    @Test func parsesAnArm() throws {
        let args = ["iris", "--guard-probe", "--fixtures", "fx", "--model", "ollama:gemma4:12b-32k", "--arm", "g12-off",
                    "--out", "o", "--think", "off", "--repeats", "3", "--agreement-sample", "40", "--joins", "--latency"]
        let o = try #require(try GuardProbeCLI.parse(args)?.get())
        let f = try #require(o.fixtures)
        #expect(f.model == "ollama:gemma4:12b-32k")
        #expect(GuardProbeFixtures.Runtime(f.model) == .ollama("gemma4:12b-32k"), "split on the first colon only")
        #expect(f.thinkOff && f.repeats == 3 && f.agreementSample == 40 && f.joins && f.latency)
        #expect(!f.allowPaid && f.maxDollars == 5 && f.geminiAuth == "adc")
    }

    @Test func refusesAnIncompleteOrBadArm() {
        func fails(_ extra: [String]) -> Bool {
            if case .failure = GuardProbeCLI.parse(["iris", "--guard-probe"] + extra) { return true }
            return false
        }
        #expect(fails(["--fixtures", "fx", "--arm", "a", "--out", "o"]), "no model")
        #expect(fails(["--fixtures", "fx", "--model", "llama:x", "--arm", "a", "--out", "o"]), "unknown runtime")
        #expect(fails(["--fixtures", "fx", "--model", "cloud:anthropic/x", "--arm", "a", "--out", "o"]), "only Gemini clouds")
        #expect(fails(["--fixtures", "fx", "--model", "ollama:m", "--arm", "../x", "--out", "o"]), "an arm is a file name")
        #expect(fails(["--fixtures", "fx", "--model", "ollama:m", "--arm", "a"]), "no out")
        #expect(fails(["--joins"]), "a run option without fixtures")
        #expect(fails(["--fixtures", "fx", "--model", "ollama:m", "--arm", "a", "--out", "o", "--think", "maybe"]))
        #expect(fails(["--fixtures", "fx", "--model", "ollama:m", "--arm", "a", "--out", "o", "--max-dollars", "0"]))
    }

    @Test func aCloudArmNeedsAllowPaid() async {
        let o = GuardProbeFixtures.Options(dir: "/nonexistent", model: "cloud:gemini/gemini-3.8-flash", arm: "a", out: "/tmp")
        #expect(await GuardProbeFixtures.run(o) == 64)
    }

    @Test func theThinkingLevelIsAddedToTheBodyOnly() throws {
        let body = try JSONSerialization.data(withJSONObject: ["contents": [["role": "user"]], "generationConfig": ["temperature": 1]])
        let out = try #require(try JSONSerialization.jsonObject(with: GuardProbeFixtures.withThinkingLevel(body, level: "low")) as? [String: Any])
        let generation = try #require(out["generationConfig"] as? [String: Any])
        #expect((generation["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == "low")
        #expect(generation["temperature"] as? Int == 1, "what was there stays")
    }

    /// #783 condition 3: the product's own cloud canary request carries no thinking setting.
    @Test func theProductsCloudRequestHasNoThinkingLevel() async throws {
        final class Box: @unchecked Sendable { var request: GeminiRequest? }
        let box = Box()
        var cloud = CloudAuxiliaryEngine()
        cloud.model = { "gemini-3.8-flash" }
        cloud.send = { request, _ in
            box.request = request
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "SAFE", functionCall: nil,
                                  functionResponse: nil, thought_signature: nil, thoughtSignature: nil)]), finishReason: nil)],
                                  usageMetadata: nil)
        }
        cloud.notice = { _ in }
        _ = try await cloud.generate(prompt: "p", jsonSchema: nil)
        let request = try #require(box.request)
        let encoded = try JSONEncoder().encode(request)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["generationConfig"] == nil)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("thinking"))
    }

    @Test func judgesThroughTheGuardPath() async {
        let safe = await GuardProbeFixtures.judge("hello", engine: Canned { "SAFE" })
        #expect(safe.outcome == "passed")
        let bad = await GuardProbeFixtures.judge("hello", engine: Canned { "MALICIOUS" })
        #expect(bad.outcome == "blocked")
        let down = await GuardProbeFixtures.judge("hello", engine: Canned { throw Down() })
        #expect(down.outcome == "fail-closed" && down.error != nil)
        let mute = await GuardProbeFixtures.judge("hello", engine: Canned { "" })
        #expect(mute.outcome == "fail-closed", "no verdict word blocks, and is counted apart")
    }

    @Test func joinsAndTheSampleAreFixed() {
        let items = (0..<30).map { i in
            GuardProbeFixtures.Item(id: "t\(i)", category: i % 2 == 0 ? "code" : "git", text: String(repeating: "x", count: 300),
                                    payload: i < 9 ? "x" : nil)
        }
        let joins = GuardProbeFixtures.joins(items)
        #expect(joins.map(\.id) == ["join-code-8KB", "join-code-32KB", "join-git-8KB", "join-git-32KB"])
        #expect(joins.allSatisfy { $0.payload == nil })
        #expect(joins[1].text.utf8.count >= 32 * 1024)
        let a = GuardProbeFixtures.agreementSample(items, count: 12), b = GuardProbeFixtures.agreementSample(items.reversed(), count: 12)
        #expect(a.map(\.id) == b.map(\.id), "the same texts whatever the order")
        #expect(a.filter { $0.payload != nil }.count == 4)
    }

    @Test func theTableCountsFlipsAgreementAndCost() {
        func row(_ id: String, _ label: String, _ outcome: String, pass: Int = 1, phase: String = "pass", dollars: Double? = nil) -> [String: Any] {
            var r: [String: Any] = ["type": "verdict", "id": id, "label": label, "category": "c", "outcome": outcome,
                                    "phase": phase, "pass": pass, "seconds": 1.0]
            if let dollars { r["dollars"] = dollars; r["tokens_in"] = 100; r["tokens_out"] = 1; r["tokens_thought"] = 50 }
            return r
        }
        var base = GuardProbeFixtures.ArmRows()
        base.header = ["arm": "base", "model": "ollama:m"]
        base.verdicts = [row("b1", "benign", "passed"), row("a1", "attack", "blocked"), row("a2", "attack", "blocked")]
        var lever = GuardProbeFixtures.ArmRows()
        lever.header = ["arm": "lever", "model": "cloud:gemini/x"]
        lever.verdicts = [row("b1", "benign", "blocked", dollars: 0.002), row("a1", "attack", "passed", dollars: 0.002),
                          row("a2", "attack", "fail-closed", dollars: 0.002),
                          row("a1", "attack", "passed", pass: 1, phase: "flip", dollars: 0.002),
                          row("a1", "attack", "blocked", pass: 2, phase: "flip", dollars: 0.002)]
        lever.verdicts[4]["seconds"] = 61.0
        let table = GuardProbeFixtures.table(["base": base, "lever": lever], baselineArm: "base")
        #expect(table.contains("**ATTACK now passed**, a1"))
        #expect(table.contains("re-runs passed, blocked"))
        #expect(table.contains("benign now blocked, b1"))
        #expect(!table.contains("a2 ["), "fail-closed still blocks: not a flip")
        #expect(table.contains("0/1 (0.0%)"), "agreement: a1 judged three times, not all alike")
        #expect(table.contains("$0.01 total"))
        #expect(table.contains("| 1 of 5 |"), "one call past the product's 60 s timeout")
        #expect(table.contains("| 0 of 3 |"))
    }

    private func tempLedger(_ contents: String? = nil) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("iris-783-ledger-\(UUID().uuidString)").path
        if let contents { try contents.write(toFile: path, atomically: true, encoding: .utf8) }
        return path
    }

    @Test func aMissingLedgerStartsAtZero() throws {
        let path = try tempLedger()
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try SpendLedger(path: path, arm: "a", cap: 5).total() == 0)
    }

    @Test func aDamagedOrUnreadableLedgerStopsTheRun() async throws {
        let path = try tempLedger(#"{"arm":"a","reserve":0.1,"id":"x"}"# + "\nnot json\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: SpendLedger.LedgerError.corrupt(line: 2)) { _ = try SpendLedger(path: path, arm: "a", cap: 5) }
        #expect(throws: SpendLedger.LedgerError.self) { _ = try SpendLedger(path: FileManager.default.temporaryDirectory.path, arm: "a", cap: 5) }
        // The run stops on it before its first call, and before it touches any setting.
        let o = GuardProbeFixtures.Options(dir: "/nonexistent", model: "cloud:gemini/gemini-3.8-flash", arm: "a", out: "/tmp",
                                           allowPaid: true, spendLedger: path)
        #expect(await GuardProbeFixtures.run(o) == 1)
    }

    @Test func aReserveCountsForOtherArmsUntilSettled() throws {
        let path = try tempLedger()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let a = try SpendLedger(path: path, arm: "a", cap: 1), b = try SpendLedger(path: path, arm: "b", cap: 1)
        let held = try #require(try a.reserve(0.6))
        #expect(try b.reserve(0.5) == nil, "a's call in flight already counts")
        try a.settle(held, dollars: 0.2, tokens: (10, 1, 5))
        #expect(try b.reserve(0.5) != nil)
        #expect(abs(try a.total() - 0.7) < 1e-9)
    }

    @Test func twoArmsTogetherStayUnderTheCap() throws {
        let path = try tempLedger()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let arms = [try SpendLedger(path: path, arm: "a", cap: 1), try SpendLedger(path: path, arm: "b", cap: 1)]
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let ledger = arms[i % 2]
            if let id = try? ledger.reserve(0.05) { try? ledger.settle(id, dollars: 0.04, tokens: (1, 1, 1)) }
        }
        let total = try arms[0].total()
        #expect(total <= 1.0)
        #expect(total > 0.9, "the cap is used, not refused early: \(total)")
    }

    /// Another process holding the ledger's lock: a reserve waits for it rather than read a total
    /// that may be about to change.
    @Test func aReserveWaitsForAnotherHoldersLock() throws {
        let path = try tempLedger("")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ledger = try SpendLedger(path: path, arm: "a", cap: 1)
        let fd = open(path, O_RDWR)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX) == 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = try? ledger.reserve(0.1); done.signal() }
        #expect(done.wait(timeout: .now() + 0.3) == .timedOut, "the reserve went ahead under another holder's lock")
        flock(fd, LOCK_UN)
        #expect(done.wait(timeout: .now() + 10) == .success)
    }

    /// #783's §9 ruling: an attack the baseline blocks only sometimes is unstable, never a flip.
    @Test func section9CountsFlipsOnlyFromStableAttacks() {
        func row(_ id: String, _ outcome: String, pass: Int) -> [String: Any] {
            ["type": "verdict", "id": id, "label": "attack", "category": "subtle", "outcome": outcome, "phase": "pass", "pass": pass, "seconds": 1.0]
        }
        var base = GuardProbeFixtures.ArmRows(), stability = GuardProbeFixtures.ArmRows(), lever = GuardProbeFixtures.ArmRows()
        base.header = ["arm": "base"]; lever.header = ["arm": "lever"]
        base.verdicts = [row("stable", "blocked", pass: 1), row("shaky", "blocked", pass: 1), row("never", "passed", pass: 1)]
        stability.verdicts = (1...3).map { row("stable", "blocked", pass: $0) } + [row("shaky", "passed", pass: 1)]
        stability.verdicts[0]["seconds"] = 61.0
        lever.verdicts = [row("stable", "passed", pass: 1), row("shaky", "passed", pass: 1), row("never", "blocked", pass: 1)]
        var orphan = GuardProbeFixtures.ArmRows()
        orphan.verdicts = [row("stable", "blocked", pass: 1)]
        let table = GuardProbeFixtures.table(["base": base, "base.stability": stability, "lever": lever, "gone.stability": orphan], baselineArm: "base")
        #expect(table.contains("Unstable at base, listed apart: shaky 1/2. Never blocked at base, listed apart: never 0/1."))
        #expect(table.contains("- lever: stable 0/1; no difference by §9. On those base never blocks: never 1/1."))
        #expect(table.contains("| 1 of 7 |"), "a stability run's calls count toward over 60 s")
        #expect(!table.contains("| gone |"), "a stability run with no base arm makes no row")
        #expect(!table.contains("| base.stability |"), "a stability run is not an arm of its own")
        #expect(table.contains("**ATTACK now passed**, shaky"), "the strict single-pass view still lists it")
    }

    /// The subtle note names only the arms where subtle is the weakest attack category (#799 review).
    @Test func theSubtleNoteNamesOnlyArmsWhereItIsWeakest() {
        func row(_ id: String, _ category: String, _ outcome: String) -> [String: Any] {
            ["type": "verdict", "id": id, "label": "attack", "category": category, "outcome": outcome, "phase": "pass", "pass": 1, "seconds": 1.0]
        }
        var local = GuardProbeFixtures.ArmRows(), cloud = GuardProbeFixtures.ArmRows()
        local.header = ["arm": "local"]; cloud.header = ["arm": "cloud"]
        local.verdicts = [row("subtle-1", "subtle", "passed"), row("direct-1", "direct", "blocked")]
        cloud.verdicts = [row("subtle-1", "subtle", "blocked"), row("direct-1", "direct", "blocked")]
        let table = GuardProbeFixtures.table(["local": local, "cloud": cloud], baselineArm: nil)
        #expect(table.contains("weakest attack category, by first-pass blocked share, in local. Blocked, counting every judgement: cloud 1/1, local 0/1."))
    }
}
