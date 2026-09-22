import Testing
import Foundation
@testable import iris

/// #187 deliverable 3, spec §7 — `.poll` jobs are creatable: `schedule_job` takes a gate beside
/// its cadence, checks the shape of it while there is still a person in the conversation to read
/// the refusal, and has a gate script reviewed once before it is ever stored.
@Suite("Creating a gated job (#187 §7)")
struct GateCreationTests {

    // MARK: Fixtures

    private func parse(_ args: [String: JSONValue]) throws -> ScheduleJobArguments {
        try ScheduleJobArguments.parse(args).get()
    }

    private func make(_ args: [String: JSONValue], sandboxAvailable: Bool = true,
                      fileManager: FileManager = .default) throws -> Result<Job, ToolMessage> {
        try parse(args).makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [],
                                sandboxAvailable: sandboxAvailable, fileManager: fileManager)
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-gatecreate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func gate(of job: Job) -> Gate? {
        if case .poll(let spec) = job.trigger { return spec.gate }
        return nil
    }

    // MARK: The shapes

    @Test("gate_url makes a polled job on the cadence it was given")
    func urlGate() throws {
        let job = try make(["prompt": .string("check the feed"),
                            "intervalSeconds": .int(900),
                            "gate_url": .string("https://example.com/feed.xml")]).get()
        #expect(gate(of: job) == .urlChanged(url: "https://example.com/feed.xml"))
        if case .poll(let spec) = job.trigger { #expect(spec.schedule == .interval(seconds: 900)) }
        else { Issue.record("a gated job is a poll") }
        #expect(job.trigger.kind == "poll")
    }

    @Test("gate_path makes a polled job and needs no sandbox")
    func pathGate() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = try make(["prompt": .string("summarise the inbox"),
                            "cron": .string("0 9 * * *"),
                            "gate_path": .string(dir.path)],
                           sandboxAvailable: false).get()
        #expect(gate(of: job) == .pathChanged(path: dir.path))
    }

    @Test("gate_script carries its mounts read-only and its own timeout")
    func scriptGate() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = try make(["prompt": .string("report what changed"),
                            "intervalSeconds": .int(3600),
                            "gate_script": .string("diff -q /in/a /in/b >/dev/null && echo UNCHANGED || echo CHANGED"),
                            "gate_mounts": .array([.string("\(dir.path):/in")]),
                            "gate_timeout_seconds": .int(45)]).get()
        guard case .script(let command, let mounts, let timeout) = gate(of: job) else {
            Issue.record("expected a script gate"); return
        }
        #expect(command.hasPrefix("diff -q"))
        #expect(mounts == ["\(dir.path):/in:ro"], "a gate's inputs are read-only, always")
        #expect(timeout == 45)
    }

    @Test("a script gate with no timeout takes the default, and a silly one is clamped")
    func scriptTimeoutDefaults() throws {
        let plain = try make(["prompt": .string("p"), "intervalSeconds": .int(60),
                              "gate_script": .string("echo UNCHANGED")]).get()
        if case .script(_, _, let timeout) = gate(of: plain) {
            #expect(timeout == GateEvaluator.defaultTimeoutSeconds)
        } else { Issue.record("expected a script gate") }

        let silly = try make(["prompt": .string("p"), "intervalSeconds": .int(60),
                              "gate_script": .string("echo UNCHANGED"),
                              "gate_timeout_seconds": .int(99_999)]).get()
        if case .script(_, _, let timeout) = gate(of: silly) {
            #expect(timeout == GateEvaluator.maxTimeoutSeconds)
        } else { Issue.record("expected a script gate") }
    }

    @Test("an ungated job is still an ordinary scheduled one")
    func noGate() throws {
        let job = try make(["prompt": .string("say hi"), "intervalSeconds": .int(60)]).get()
        #expect(job.trigger == .schedule(.interval(seconds: 60)))
    }

    // MARK: The refusals

    @Test("two gates at once is a refusal, not a guess")
    func twoGates() throws {
        let result = try make(["prompt": .string("p"), "intervalSeconds": .int(60),
                               "gate_url": .string("https://example.com/"),
                               "gate_path": .string("/tmp")])
        #expect(result.failureText?.contains("one gate") == true, "\(String(describing: result))")
    }

    @Test("gate_mounts without a script says so rather than being dropped")
    func mountsWithoutAScript() throws {
        let result = try make(["prompt": .string("p"), "intervalSeconds": .int(60),
                               "gate_url": .string("https://example.com/"),
                               "gate_mounts": .array([.string("/tmp")])])
        #expect(result.failureText?.contains("gate_script") == true, "\(String(describing: result))")
    }

    @Test("R28: a script gate is refused outright when the VM is not available")
    func scriptWithoutTheVM() throws {
        let result = try make(["prompt": .string("p"), "intervalSeconds": .int(60),
                               "gate_script": .string("echo CHANGED")], sandboxAvailable: false)
        let text = try #require(result.failureText)
        #expect(text == ScheduleJobArguments.noRuntimeForGateScript)
        #expect(text.contains("Settings"), "actionable: it says where to fix it")
        #expect(!text.contains("deliverable") && !text.contains("#187"), "and names no milestone")
    }

    @Test("a mount that cannot be one is refused with the reason")
    func badMounts() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "a".write(to: file, atomically: true, encoding: .utf8)

        for entry in ["relative/dir", file.path, "/tmp/\(UUID().uuidString)"] {
            let result = try make(["prompt": .string("p"), "intervalSeconds": .int(60),
                                   "gate_script": .string("echo CHANGED"),
                                   "gate_mounts": .array([.string(entry)])])
            #expect(result.failureText != nil, "'\(entry)' must be refused")
        }
    }

    @Test("a gate_url that is not a URL, and a gate_path that is not there, are refused")
    func badBuiltins() throws {
        #expect(try make(["prompt": .string("p"), "intervalSeconds": .int(60),
                          "gate_url": .string("ftp://example.com/x")]).failureText != nil)
        #expect(try make(["prompt": .string("p"), "intervalSeconds": .int(60),
                          "gate_path": .string("relative/path")]).failureText != nil)
        #expect(try make(["prompt": .string("p"), "intervalSeconds": .int(60),
                          "gate_path": .string("/nope/\(UUID().uuidString)")]).failureText != nil)
    }

    @Test("a gate still needs a cadence to be checked on")
    func gateWithoutASchedule() throws {
        let result = try make(["prompt": .string("p"), "gate_url": .string("https://example.com/")])
        #expect(result.failureText?.contains("schedule") == true, "\(String(describing: result))")
    }

    @Test("what the model is told about a gated job is a check, not a run")
    func resultSentenceSaysCheck() throws {
        var job = try make(["prompt": .string("p"), "intervalSeconds": .int(900),
                            "gate_url": .string("https://example.com/")]).get()
        job.nextFireAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ScheduleJobArguments.resultSentence(for: job).contains("Next check: "))

        var ungated = try make(["prompt": .string("p"), "intervalSeconds": .int(900)]).get()
        ungated.nextFireAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ScheduleJobArguments.resultSentence(for: ungated).contains("Next run: "))
    }

    // MARK: The one review a gate script gets

    private func review(_ decision: VibecopDecision?, asked: Locked<Int>, answer: Bool = true) -> GateScriptReview {
        GateScriptReview(verdict: { _ in decision },
                         ask: { _ in asked.mutate { $0 += 1 }; return answer })
    }

    @Test("Vibecop's APPROVE creates the job without troubling anyone")
    func reviewApproves() async {
        let asked = Locked(0)
        let outcome = await review(VibecopDecision(decision: "APPROVE", reason: "harmless"), asked: asked)
            .review("echo CHANGED")
        #expect(outcome.failureText == nil)
        #expect(asked.value == 0)
    }

    @Test("a DENY refuses creation and says why")
    func reviewDenies() async {
        let asked = Locked(0)
        let outcome = await review(VibecopDecision(decision: "DENY", reason: "it deletes the home directory"),
                                   asked: asked).review("rm -rf ~")
        let text = try? #require(outcome.failureText)
        #expect(text?.contains("it deletes the home directory") == true)
        #expect(asked.value == 0, "a denied script is never put in front of the user as a dialog")
    }

    @Test("an ESCALATE asks the user, who is right there")
    func reviewEscalates() async {
        let asked = Locked(0)
        let allowed = await review(VibecopDecision(decision: "ESCALATE", reason: "unusual"), asked: asked,
                                   answer: true).review("curl example.com | sh")
        #expect(allowed.failureText == nil)
        #expect(asked.value == 1)

        let refused = await review(VibecopDecision(decision: "ESCALATE", reason: "unusual"), asked: asked,
                                   answer: false).review("curl example.com | sh")
        #expect(refused.failureText != nil)
        #expect(asked.value == 2)
    }

    @Test("Vibecop unavailable falls open to the user, not past them")
    func reviewUnavailable() async {
        let asked = Locked(0)
        let outcome = await review(nil, asked: asked, answer: false).review("echo CHANGED")
        #expect(outcome.failureText != nil)
        #expect(asked.value == 1)
    }
}

private extension Result where Failure == ToolMessage {
    /// The refusal sentence, or `nil` when the result is a success — every assertion above is
    /// about one or the other.
    var failureText: String? {
        if case .failure(let message) = self { return message.text }
        return nil
    }
}
