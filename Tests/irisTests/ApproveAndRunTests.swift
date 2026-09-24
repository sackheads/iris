import Testing
import Foundation
@testable import iris

/// #187 §6 — the persisted blocked call and "Approve and run". A background run that failed closed
/// records the whole call; the card shows it, with Vibecop's opinion of it beside the button; and a
/// click dispatches exactly that one call, once, as a tracked run of its own.
///
/// The two refusals a click cannot lift are the point of most of this file: a `.profile` denial
/// (R13 — the job is read-only, and no human approval widens that) and a write into a protected
/// directory (R10 — `~/.iris/config` and `~/.iris/plugins` are where permission is granted, so a
/// write there is a grant, not an edit). Both are checked on the card, in the runner and in the
/// executor, because each of the three can be reached without the other two.
@MainActor
@Suite("Approve and run (#187)")
struct ApproveAndRunTests {

    // MARK: Fixtures

    private func harness(_ responses: [GeminiResponse] = [], autoApprove: Bool = false)
        throws -> (ConversationStore, AppState, IrisEngine) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = autoApprove
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: responses),
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine)
    }

    /// A settings store of this suite's own (AGENTS invariant 7): `JobRunner` resolves limits and
    /// the Vibecop gate through a `ConfigManager`, and the default is the process-global one.
    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-approve-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func job(name: String = "pr-sweep", profile: JobProfile = .mutating) -> Job {
        Job(name: name, prompt: "Do the thing.", trigger: .schedule(.interval(seconds: 60)),
            profile: profile)
    }

    /// A finished `blockedOnApproval` run with `call` persisted on it — what Task 4 leaves behind,
    /// written straight to the ledger so a test about approving it does not also have to drive a
    /// whole turn.
    @discardableResult
    private func blockedRun(_ call: BlockedCall, job: Job, ledger: JobLedger,
                            conversationId: UUID? = nil) throws -> JobRun {
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                         startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                         transcriptConversationId: conversationId)
        try ledger.begin(run: run)
        try ledger.finish(runId: run.id, status: .blockedOnApproval, outcome: nil,
                          failureReason: "needs approval: \(call.toolName)",
                          blockedTool: call.toolName, tokens: TokenUsage(),
                          finishedAt: Date(timeIntervalSince1970: 1_700_000_001))
        try ledger.setBlockedCall(runId: run.id, call)
        return try #require(try ledger.run(id: run.id))
    }

    private func tempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-approve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Answers every Vibecop prompt with a fixed verdict and counts how often it was asked. The
    /// task-local seam (#237) — nothing here touches `VibecopService.shared`'s real engine.
    private final class SpyVibecop: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var lastPromptText = ""
        let decision: String
        let reason: String
        init(decision: String, reason: String = "looks destructive") {
            self.decision = decision
            self.reason = reason
        }
        var calls: Int { lock.withLock { count } }
        var lastPrompt: String { lock.withLock { lastPromptText } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            lock.withLock { count += 1; lastPromptText = prompt }
            return #"{"decision":"\#(decision)","reason":"\#(reason)"}"#
        }
    }

    // MARK: The persisted call, on the card

    @Test("a blocked run persists the whole call and the card carries it")
    func blockedRunPersistsTheWholeCall() async throws {
        // Unique and inert: `PermissionManager` matches a rule on the exact command string, so no
        // allowlist on the machine running this can already hold it.
        let command = "true --never-run-\(UUID().uuidString)"
        let (store, state, engine) = try harness([
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(functionCall: FunctionCall(name: "run_command",
                                                args: ["command": .string(command)]))]))],
                           usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(text: "I could not do that.")]))], usageMetadata: nil),
        ])
        let job = self.job(name: "needs-hands")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })

        await runner.fire(job: job, origin: .schedule)

        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        let stored = try #require(run.blockedCall)
        #expect(stored.toolName == "run_command")
        #expect(stored.args["command"]?.stringValue == command)
        #expect(stored.reason == .approval)

        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.first)
        let onCard = try #require(card.blockedCall)
        #expect(onCard.toolName == "run_command")
        #expect(onCard.args["command"]?.stringValue == command)
        #expect(card.offersApproval, "an approval denial is exactly what a person can act on")
    }

    @Test("the card previews a long argument rather than pasting it whole")
    func cardPreviewsLongArguments() {
        let body = String(repeating: "x", count: 1_200)
        let card = EventCard(runId: UUID(), jobId: UUID(), jobName: "writer", status: .blockedOnApproval,
                             startedAt: Date(), finishedAt: Date(),
                             blockedCall: BlockedCall(toolName: "write_file",
                                                      args: ["path": .string("/tmp/out.txt"),
                                                             "content": .string(body)],
                                                      cwd: "/tmp"))
        let arguments = card.blockedArguments
        #expect(arguments.map(\.key) == ["content", "path"], "sorted, so two renders read the same")
        let content = try! #require(arguments.first { $0.key == "content" })
        #expect(content.value.hasPrefix(String(repeating: "x", count: EventCard.argumentPreviewLimit)))
        #expect(content.value.count < body.count)
        #expect(content.value.contains("1200"), "and it says how much was cut")
        #expect(arguments.first { $0.key == "path" }?.value == "/tmp/out.txt")
    }

    @Test("an execution-bearing argument is shown whole; a content one is capped with its count")
    func executionBearingArgumentsAreNeverCut() throws {
        // The argument a click authorises is the one a cut would hide, so `command` and `path`
        // survive whole while `content` — what the tool stores rather than executes — is capped.
        let command = String(repeating: "a", count: 600)
        let body = String(repeating: "b", count: 600)
        let path = "/tmp/" + String(repeating: "d", count: 600)
        let card = EventCard(runId: UUID(), jobId: UUID(), jobName: "sweeper", status: .blockedOnApproval,
                             startedAt: Date(), finishedAt: Date(),
                             blockedCall: BlockedCall(toolName: "run_command",
                                                      args: ["command": .string(command),
                                                             "content": .string(body),
                                                             "path": .string(path)],
                                                      cwd: "/tmp"))
        let arguments = Dictionary(uniqueKeysWithValues: card.blockedArguments.map { ($0.key, $0.value) })
        #expect(arguments["command"] == command, "600 characters of shell, all 600 readable")
        #expect(arguments["path"] == path)
        let content = try #require(arguments["content"])
        #expect(content.hasPrefix(String(repeating: "b", count: EventCard.argumentPreviewLimit)))
        #expect(content.contains("600 characters"), "and it says how much was cut")
        #expect(content.count < body.count)
        // The card's stored copy takes the same split: the ledger's untruncated call is what runs.
        let display = EventCard.displayCopy(of: try #require(card.blockedCall))
        #expect(display.args["command"]?.stringValue == command)
        let storedContent = try #require(display.args["content"]?.stringValue)
        #expect(storedContent.count < body.count)
    }

    @Test("a newline flood cannot stretch the card: blank runs collapse and the lines are capped")
    func previewNormalisesNewlines() throws {
        // Layout itself is not unit-testable — that a `Text` lays out in full is `fixedSize`'s
        // job and SwiftUI's. What IS testable, and what bounds the card's height, is that the
        // string handed to that `Text` has a bounded number of lines whatever is poured into it.
        let flood = String(repeating: "\n", count: 500)
        let shown = EventCard.preview(key: "content", value: .string("start" + flood + "end"))
        #expect(shown.components(separatedBy: "\n").count <= EventCard.argumentPreviewLines,
                "500 blank lines collapse to one gap, so nothing is left to cap")
        #expect(shown.contains("start") && shown.contains("end"))

        // Non-blank lines are real content, so they are capped rather than collapsed, and the cut
        // says how many it hid — the same `… (N …)` style the character cap uses.
        let manyLines = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let capped = EventCard.preview(key: "content", value: .string(manyLines))
        #expect(capped.components(separatedBy: "\n").count == EventCard.argumentPreviewLines)
        #expect(capped.hasSuffix("… (\(100 - EventCard.argumentPreviewLines) more lines)"))
        #expect(capped.hasPrefix("line 1\n"))

        // Both cuts at once still report both: a wall of long lines loses characters AND lines,
        // and the note names each, because a truncation the reader cannot see is the failure mode.
        let wall = (1...100).map { String(repeating: "w", count: 200) + "\($0)" }.joined(separator: "\n")
        let both = EventCard.preview(key: "content", value: .string(wall))
        #expect(both.contains("characters,") && both.hasSuffix("more lines)"))
        #expect(both.count < EventCard.argumentPreviewLimit + 60)

        // The bound holds for an execution-bearing argument too: it is exempt from the character
        // cap, not from having a height — and with no character cut ahead of it the line count is
        // exact.
        let longCommand = (1...100).map { "echo \($0)" }.joined(separator: "\n")
        let cappedCommand = EventCard.preview(key: "command", value: .string(longCommand))
        #expect(cappedCommand.components(separatedBy: "\n").count == EventCard.argumentPreviewLines)
        #expect(cappedCommand.hasSuffix("… (\(100 - EventCard.argumentPreviewLines) more lines)"))
        #expect(cappedCommand.hasPrefix("echo 1\n"))

        // One hidden line is "1 more line", not "1 more lines".
        let oneOver = (1...(EventCard.argumentPreviewLines + 1)).map { "x\($0)" }.joined(separator: "\n")
        #expect(EventCard.preview(key: "content", value: .string(oneOver)).hasSuffix("… (1 more line)"))
    }

    @Test("a profile denial is never offered an Approve button (R13)")
    func profileDenialIsNotApprovable() {
        let card = EventCard(runId: UUID(), jobId: UUID(), jobName: "reader", status: .blockedOnApproval,
                             startedAt: Date(), finishedAt: Date(),
                             blockedCall: BlockedCall(toolName: "write_file",
                                                      args: ["path": .string("/tmp/x")],
                                                      reason: .profile))
        #expect(!card.offersApproval)
        #expect(card.approvalRefusal == EventCard.profileNotApprovable)
        // Even round-tripped through a build that wrote no refusal of its own: the reason on the
        // call is enough, so an older card cannot offer a button this build would refuse.
        let reencoded = try! #require(EventCard.decode(card.encodedContent()))
        #expect(!reencoded.offersApproval)
    }

    @Test("a card with no blocked call offers nothing and says nothing about approving")
    func plainCardOffersNothing() {
        let card = EventCard(runId: UUID(), jobId: UUID(), jobName: "quiet", status: .completed,
                             outcome: "tick", startedAt: Date(), finishedAt: Date())
        #expect(!card.offersApproval)
        #expect(card.approvalRefusal == nil)
        #expect(card.blockedArguments.isEmpty)
        #expect(card.vibecopLine == nil)
    }

    @Test("the card's new fields survive a round trip, and an older card without them still decodes")
    func cardRoundTripsTheNewFields() throws {
        let card = EventCard(runId: UUID(), jobId: UUID(), jobName: "writer", status: .blockedOnApproval,
                             startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                             finishedAt: Date(timeIntervalSince1970: 1_700_000_060),
                             blockedCall: BlockedCall(toolName: "run_command",
                                                      args: ["command": .string("rm -rf /tmp/x")],
                                                      cwd: "/tmp"),
                             vibecopVerdict: "DENY", vibecopReason: "recursive delete")
        let decoded = try #require(EventCard.decode(card.encodedContent()))
        #expect(decoded.blockedCall?.toolName == "run_command")
        #expect(decoded.blockedCall?.args["command"]?.stringValue == "rm -rf /tmp/x")
        #expect(decoded.blockedCall?.cwd == "/tmp")
        #expect(decoded.vibecopLine == "Vibecop: DENY — recursive delete")
        #expect(decoded.offersApproval, "a DENY is information, not a veto: the person decides")

        let older = try #require(EventCard.decode(#"{"runId":"\#(UUID().uuidString)","jobName":"old"}"#))
        #expect(older.blockedCall == nil)
        #expect(!older.offersApproval)
    }

    // MARK: Vibecop when the card is built

    @Test("Vibecop is consulted when the card is built and its verdict rides on the card")
    func vibecopVerdictReachesTheCard() async throws {
        let command = "true --never-run-\(UUID().uuidString)"
        let (store, state, engine) = try harness([
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(functionCall: FunctionCall(name: "run_command",
                                                args: ["command": .string(command)]))]))],
                           usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(text: "blocked.")]))], usageMetadata: nil),
        ])
        let job = self.job(name: "watched")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.enableVibecop = true
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })
        let spy = SpyVibecop(decision: "DENY", reason: "this deletes things")

        await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": spy]) {
            await runner.fire(job: job, origin: .schedule)
        }

        #expect(spy.calls == 1, "the verdict is taken once, when the card is written")
        #expect(spy.lastPrompt.contains(command), "and it is asked about the call that was refused")
        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.first)
        #expect(card.vibecopVerdict == "DENY")
        #expect(card.vibecopReason == "this deletes things")
        #expect(card.offersApproval, "a human click overrides a DENY; it does not skip the evaluation")
    }

    @Test("nothing is asked of Vibecop for a call no click can approve")
    func vibecopIsNotConsultedForAProfileDenial() async throws {
        let (store, state, engine) = try harness([
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(functionCall: FunctionCall(name: "write_file",
                                                args: ["path": .string("/tmp/x"),
                                                       "content": .string("hi")]))]))],
                           usageMetadata: nil),
        ])
        let job = self.job(name: "reader", profile: .readOnly)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.enableVibecop = true
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config)
        let spy = SpyVibecop(decision: "APPROVE")

        await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": spy]) {
            await runner.fire(job: job, origin: .schedule)
        }

        #expect(spy.calls == 0)
        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.first)
        #expect(card.blockedCall?.reason == .profile)
        #expect(!card.offersApproval)
        #expect(card.vibecopVerdict == nil)
    }

    @Test("the verdict is taken in the context the approved call will actually run in")
    func verdictFollowsTheExecutorsSandboxRule() async throws {
        let (store, state, engine) = try harness()
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.enableVibecop = true
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })
        // The context line Vibecop is given when the call runs inside the VM.
        let inVM = "EXECUTION CONTEXT"

        // A mutating job's approved call opens a sandboxed conversation whatever the tool is, so
        // that is the context the verdict has to be taken in.
        let mutatingJob = job(name: "writer", profile: .mutating)
        let write = BlockedCall(toolName: "write_file", args: ["path": .string("/tmp/x")])
        let writeSpy = SpyVibecop(decision: "APPROVE")
        await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": writeSpy]) {
            _ = await runner.approvalOffer(for: write, job: mutatingJob)
        }
        #expect(writeSpy.calls == 1)
        #expect(writeSpy.lastPrompt.contains(inVM),
                "a mutating job's call is run in the VM, so the verdict is asked about the VM")

        // A read-only job's `run_command` is the container's or nobody's, so it is sandboxed too.
        let readerJob = job(name: "reader", profile: .readOnly)
        let command = BlockedCall(toolName: "run_command", args: ["command": .string("ls")])
        let commandSpy = SpyVibecop(decision: "APPROVE")
        await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": commandSpy]) {
            _ = await runner.approvalOffer(for: command, job: readerJob)
        }
        #expect(commandSpy.lastPrompt.contains(inVM))

        // Anything else takes the host path under the user's allowlist, and is judged as such.
        let hostSpy = SpyVibecop(decision: "APPROVE")
        await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": hostSpy]) {
            _ = await runner.approvalOffer(for: BlockedCall(toolName: "send_mail"), job: readerJob)
        }
        #expect(!hostSpy.lastPrompt.contains(inVM))
    }

    // MARK: runApproved

    @Test("Approve and run executes exactly the persisted call as its own tracked run")
    func approvedCallRunsAsItsOwnRun() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("approved.txt").path
        let (store, state, engine) = try harness()
        let job = self.job(name: "writer")
        try store.ledger.upsert(job)
        let call = BlockedCall(toolName: "write_file",
                               args: ["path": .string(target), "content": .string("written once")],
                               cwd: dir.path)
        let blocked = try blockedRun(call, job: job, ledger: store.ledger)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })

        let outcome = await runner.runApproved(runId: blocked.id)

        guard case .dispatched(let approvedRunId) = outcome else {
            Issue.record("the approval was refused: \(outcome)")
            return
        }
        #expect(FileManager.default.contents(atPath: target).map { String(decoding: $0, as: UTF8.self) }
                == "written once")

        let approved = try #require(try store.ledger.run(id: approvedRunId))
        #expect(approved.triggerKind == "approval")
        #expect(approved.parentRunId == blocked.id)
        #expect(approved.jobId == job.id)
        #expect(approved.status == .completed)
        #expect(approved.outcome?.hasPrefix("Successfully wrote to ") == true)

        // A hidden conversation of its own, named for the call it ran.
        let conversation = try #require(state.conversations.first {
            $0.id == approved.transcriptConversationId
        })
        #expect(conversation.isBackground)
        #expect(conversation.title == "writer · approved write_file")
        #expect(conversation.messages.contains { $0.role == .system && $0.content.contains(target) })
        #expect(conversation.history.isEmpty, "no model turn: the call is dispatched, not resumed")

        // The claim is stamped on the run that asked, and a follow-up card reports the result.
        #expect(try store.ledger.run(id: blocked.id)?.approvedAt != nil)
        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.last)
        #expect(card.runId == approvedRunId)
        #expect(card.status == .completed)
        #expect(card.outcome?.hasPrefix("Successfully wrote to ") == true)
        #expect(card.blockedCall == nil, "the follow-up card has nothing left to approve")
    }

    @Test("a second click runs nothing and writes no second row")
    func approveIsOneShot() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("once.txt").path
        let (store, state, engine) = try harness()
        let job = self.job(name: "writer")
        try store.ledger.upsert(job)
        let blocked = try blockedRun(BlockedCall(toolName: "write_file",
                                                 args: ["path": .string(target),
                                                        "content": .string("first")],
                                                 cwd: dir.path),
                                     job: job, ledger: store.ledger)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })

        _ = await runner.runApproved(runId: blocked.id)
        try? FileManager.default.removeItem(atPath: target)
        let second = await runner.runApproved(runId: blocked.id)

        #expect(second == .refused(JobRunner.alreadyApprovedRefusal))
        #expect(!FileManager.default.fileExists(atPath: target), "the call did not run a second time")
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 2, "one blocked row, one approved")
    }

    @Test("a claim stamped before the app went down is not honoured again after it comes back")
    func aStampedClaimSurvivesARestart() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("never.txt").path
        let (store, state, engine) = try harness()
        let job = self.job(name: "writer")
        try store.ledger.upsert(job)
        let blocked = try blockedRun(BlockedCall(toolName: "write_file",
                                                 args: ["path": .string(target),
                                                        "content": .string("no")],
                                                 cwd: dir.path),
                                     job: job, ledger: store.ledger)
        // The claim is taken before the call is dispatched, so this is the state a crash between
        // the click and the execution leaves behind — and a fresh runner must not re-run it.
        #expect(try store.ledger.markApproved(runId: blocked.id, at: Date()))
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })

        #expect(await runner.runApproved(runId: blocked.id) == .refused(JobRunner.alreadyApprovedRefusal))
        #expect(!FileManager.default.fileExists(atPath: target))
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 1)
    }

    @Test("a deleted job has nothing to approve")
    func deletedJobIsRefused() async throws {
        let (store, state, engine) = try harness()
        let job = self.job(name: "gone")
        try store.ledger.upsert(job)
        let blocked = try blockedRun(BlockedCall(toolName: "run_command",
                                                 args: ["command": .string("echo hi")]),
                                     job: job, ledger: store.ledger)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })
        // The run row cascades away with the job, so this is also the "row is gone" case.
        try store.ledger.delete(jobId: job.id)

        #expect(await runner.runApproved(runId: blocked.id) == .refused(JobRunner.missingRunRefusal))
        #expect(state.conversations.filter { $0.isBackground }.isEmpty)
        // There is no job left to ask where its news goes, so the answer goes to Activity rather
        // than nowhere: the card the person clicked is still on screen.
        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        #expect(activity.messages.contains {
            $0.content == JobRunner.refusalNotice(JobRunner.missingRunRefusal)
        })
    }

    @Test("a read-only job's refused call is not approvable, whichever door it is tried at (R13)")
    func profileDenialIsRefusedByTheRunner() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("readonly.txt").path
        let (store, state, engine) = try harness()
        let job = self.job(name: "reader", profile: .readOnly)
        try store.ledger.upsert(job)
        let blocked = try blockedRun(BlockedCall(toolName: "write_file",
                                                 args: ["path": .string(target),
                                                        "content": .string("nope")],
                                                 cwd: dir.path, reason: .profile),
                                     job: job, ledger: store.ledger)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config)

        #expect(await runner.runApproved(runId: blocked.id) == .refused(JobRunner.profileNotApprovableRefusal))
        #expect(!FileManager.default.fileExists(atPath: target))
        // Said out loud, where the card is — this job has no destination, so that is Activity.
        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        #expect(activity.messages.contains {
            $0.content == JobRunner.refusalNotice(JobRunner.profileNotApprovableRefusal)
        })
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 1)
        // And the data layer refuses it too, even if something skipped the runner entirely.
        #expect(try store.ledger.markApproved(runId: blocked.id, at: Date()) == false)
    }

    @Test("a mutating job's approved call runs in the container, and not at all without one")
    func approvedCallInAMutatingJobIsSandboxed() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness()
        let job = self.job(name: "builder", profile: .mutating)
        try store.ledger.upsert(job)
        let call = BlockedCall(toolName: "write_file",
                               args: ["path": .string(dir.appendingPathComponent("a.txt").path),
                                      "content": .string("a")],
                               cwd: dir.path)
        let blocked = try blockedRun(call, job: job, ledger: store.ledger)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }

        // No VM: the call is refused rather than run on the host (R12).
        let noSandbox = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                                  sandboxAvailable: { false })
        #expect(await noSandbox.runApproved(runId: blocked.id)
                == .refused(JobRunner.sandboxUnavailableReason))
        #expect(try store.ledger.run(id: blocked.id)?.approvedAt == nil,
                "a refused dispatch does not burn the one-shot claim")
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 1)

        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })
        guard case .dispatched(let approvedRunId) = await runner.runApproved(runId: blocked.id) else {
            Issue.record("the approval was refused")
            return
        }
        let approved = try #require(try store.ledger.run(id: approvedRunId))
        let conversation = try #require(state.conversations.first {
            $0.id == approved.transcriptConversationId
        })
        #expect(conversation.mainAgentSandbox == .sandboxed,
                "the approved call runs with the job's own sandbox setting")
        #expect(conversation.jobProfile == .mutating)
    }

    // MARK: R20 — the profile is re-asked at click time

    @Test("a read-only job's approved command is refused when the container has gone, and never runs on the host")
    func readOnlyApprovedCommandNeedsTheContainer() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ran-on-the-host").path
        let (store, state, engine) = try harness()
        // A `readOnly` job whose `run_command` was allowed by the profile at fire time (it was
        // sandboxed then) and refused only for want of a human — so the reason is `.approval` and
        // R13 does not cover it. Between that run and this click the runtime went away.
        let job = self.job(name: "reader", profile: .readOnly)
        try store.ledger.upsert(job)
        let call = BlockedCall(toolName: "run_command",
                               args: ["command": .string("touch \(marker)")], cwd: dir.path)
        let blocked = try blockedRun(call, job: job, ledger: store.ledger)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { false })

        let outcome = await runner.runApproved(runId: blocked.id)

        #expect(outcome == .refused(JobRunner.sandboxUnavailableReason))
        #expect(!FileManager.default.fileExists(atPath: marker), "it never reached the host executor")
        #expect(try store.ledger.run(id: blocked.id)?.approvedAt == nil, "the claim is not burnt")
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 1)
        // And the person who clicked is told, where they clicked.
        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        #expect(activity.messages.contains {
            $0.role == .system
                && $0.content == JobRunner.refusalNotice(JobRunner.sandboxUnavailableReason)
        })
    }

    @Test("an approved command is pinned to the container, and refused rather than run outside it")
    func approvedCommandIsPinnedToTheContainer() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ran-on-the-host").path
        let (store, state, engine) = try harness()
        let job = self.job(name: "reader", profile: .readOnly)
        try store.ledger.upsert(job)
        let blocked = try blockedRun(BlockedCall(toolName: "run_command",
                                                 args: ["command": .string("touch \(marker)")],
                                                 cwd: dir.path),
                                     job: job, ledger: store.ledger)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        // The runner's own seam says the VM is there, so admission lets the call through.
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })

        guard case .dispatched(let approvedRunId) = await runner.runApproved(runId: blocked.id) else {
            Issue.record("the approval was refused before it could be dispatched")
            return
        }

        let approved = try #require(try store.ledger.run(id: approvedRunId))
        let conversation = try #require(state.conversations.first {
            $0.id == approved.transcriptConversationId
        })
        // R20: the pin is not conditioned on `.mutating` — a read-only job's approved command asks
        // for the container too, because the host is where its containment would end.
        #expect(conversation.mainAgentSandbox == .sandboxed)
        // A test process has sandboxing off (as `JobRunnerTests` also assumes), so the pin cannot
        // be honoured and the executor refuses instead of falling back to the host. Whatever this
        // machine's runtime says, the one thing that must never happen is the host run.
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(approved.status == .failed)
        #expect(approved.outcome?.contains("sandbox unavailable") == true)
    }

    // MARK: Where a refusal is said, and what a dispatch leaves behind

    @Test("a refused click is reported in the conversation the card is in")
    func aRefusalLandsWhereTheCardIs() async throws {
        let (store, state, engine) = try harness()
        let destination = state.createNewConversation(title: "Work")
        let job = Job(name: "writer", prompt: "x", trigger: .schedule(.interval(seconds: 60)),
                      profile: .mutating, destinationConversationId: destination)
        try store.ledger.upsert(job)
        let blocked = try blockedRun(BlockedCall(toolName: "run_command",
                                                 args: ["command": .string("echo hi")]),
                                     job: job, ledger: store.ledger)
        // Already claimed: the refusal every second click gets.
        #expect(try store.ledger.markApproved(runId: blocked.id, at: Date()))
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })

        #expect(await runner.runApproved(runId: blocked.id) == .refused(JobRunner.alreadyApprovedRefusal))

        let notice = JobRunner.refusalNotice(JobRunner.alreadyApprovedRefusal)
        let card = try #require(state.conversations.first { $0.id == destination })
        #expect(card.messages.contains { $0.role == .system && $0.content == notice },
                "the sentence lands where the person clicked")
        let activity = state.conversations.first { $0.id == state.activityConversationId() }
        #expect(activity?.messages.contains { $0.content == notice } != true,
                "and not in a conversation they may not have open")
    }

    @Test("two clicks racing each other still run the call once")
    func concurrentClicksRaceForOneClaim() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("raced.txt").path
        let (store, state, engine) = try harness()
        let job = self.job(name: "writer")
        try store.ledger.upsert(job)
        let blocked = try blockedRun(BlockedCall(toolName: "write_file",
                                                 args: ["path": .string(target),
                                                        "content": .string("once")],
                                                 cwd: dir.path),
                                     job: job, ledger: store.ledger)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })

        // The claim is one conditional UPDATE, so the two can interleave at every await before it
        // and still only one can win.
        async let first = runner.runApproved(runId: blocked.id)
        async let second = runner.runApproved(runId: blocked.id)
        let outcomes = await [first, second]

        #expect(outcomes.filter { if case .dispatched = $0 { return true } else { return false } }.count == 1)
        #expect(outcomes.contains(.refused(JobRunner.alreadyApprovedRefusal)))
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 2, "one blocked row, one approved")
    }

    // MARK: R10 — the protected directories, at all three doors

    @Test("the card never offers to approve a write into a protected directory (R10)")
    func protectedWriteIsNotOfferedOnTheCard() async throws {
        let home = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = IrisPaths(root: home)
        let target = paths.configDir.appendingPathComponent("permissions.json").path
        let (store, state, engine) = try harness([
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(functionCall: FunctionCall(name: "write_file",
                                                args: ["path": .string(target),
                                                       "content": .string("[]")]))]))],
                           usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(text: "refused.")]))], usageMetadata: nil),
        ])
        state.permissions = PermissionManager(paths: paths)
        let job = self.job(name: "grabby")
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        config.enableVibecop = true
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })
        let spy = SpyVibecop(decision: "APPROVE")

        await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": spy]) {
            await runner.fire(job: job, origin: .schedule)
        }

        #expect(!FileManager.default.fileExists(atPath: target), "the run itself never wrote it")
        let activity = try #require(state.conversations.first { $0.id == state.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.first)
        #expect(card.blockedCall?.toolName == "write_file")
        #expect(!card.offersApproval)
        #expect(card.approvalRefusal == EventCard.protectedNotApprovable)
        #expect(spy.calls == 0, "nothing is asked about a call no click can authorise")

        // And the click itself is refused, if the button is reached some other way.
        let blocked = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(await runner.runApproved(runId: blocked.id)
                == .refused(JobRunner.protectedWriteRefusal))
        #expect(!FileManager.default.fileExists(atPath: target))
        #expect(try store.ledger.runs(jobId: job.id, limit: 10).count == 1)
    }

    @Test("the executor refuses a protected write even with the approval already granted (R10)")
    func executorRefusesAProtectedWrite() async throws {
        let (_, state, engine) = try harness()
        let home = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = IrisPaths(root: home)
        state.permissions = PermissionManager(paths: paths)
        let conversationId = state.createNewConversation(isBackground: true, title: "approved")
        // A symlink into the protected directory, planted where a job may write: the check is
        // canonical, so this is the same refusal as naming `config/` outright.
        let link = home.appendingPathComponent("memory/cfg")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: paths.configDir)
        let target = link.appendingPathComponent("permissions.json").path
        let call = BlockedCall(toolName: "write_file",
                               args: ["path": .string(target), "content": .string("[]")])

        let result = await engine.executeApprovedCall(call, conversationId: conversationId)

        #expect(result == IrisEngine.protectedWriteRefusal(tool: "write_file"))
        #expect(!FileManager.default.fileExists(atPath: paths.configDir
                                                     .appendingPathComponent("permissions.json").path))
    }

    @Test("an approved call's own conversation still fails closed if anything asks in it again")
    func theApprovedConversationIsNotLeftPreAuthorised() async throws {
        // R21: there is no pre-granted-approval branch in `requestApproval` any more — the
        // approved call is dispatched straight into `executeToolWithHooks`, so the conversation it
        // runs in is an ordinary background one and a nested ask from inside it is refused like
        // any other unattended call.
        let (_, state, _) = try harness()
        let home = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        state.permissions = PermissionManager(paths: IrisPaths(root: home))
        let conversationId = state.createNewConversation(isBackground: true, title: "approved")

        let command = "true --never-run-\(UUID().uuidString)"
        #expect(await state.requestApproval(toolName: "run_command", details: command,
                                            conversationId: conversationId) == false)
        #expect(state.firstBackgroundDenial(for: conversationId)?.toolName == "run_command")
    }

    @Test("the executor refuses a profile denial even if one reaches it")
    func executorRefusesAProfileDenial() async throws {
        // R13's fourth door: the card hides the button, `runApproved` refuses the click and
        // `markApproved` refuses the claim — this is the backstop for whatever calls in next.
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, state, engine) = try harness()
        let conversationId = state.createNewConversation(isBackground: true, title: "approved")
        let target = dir.appendingPathComponent("profile.txt").path
        let call = BlockedCall(toolName: "write_file",
                               args: ["path": .string(target), "content": .string("no")],
                               cwd: dir.path, reason: .profile)

        let result = await engine.executeApprovedCall(call, conversationId: conversationId)

        #expect(result == IrisEngine.profileNotApprovableRefusal(tool: "write_file"))
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test("approving a blocked run also takes it out of the failure list")
    func approvingAcknowledgesTheParentRow() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, state, engine) = try harness()
        let job = self.job(name: "writer")
        try store.ledger.upsert(job)
        let blocked = try blockedRun(BlockedCall(
            toolName: "write_file",
            args: ["path": .string(dir.appendingPathComponent("ack.txt").path),
                   "content": .string("ack")], cwd: dir.path), job: job, ledger: store.ledger)
        #expect(try store.ledger.unacknowledgedFailures().map(\.id) == [blocked.id])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               sandboxAvailable: { true })

        guard case .dispatched = await runner.runApproved(runId: blocked.id) else {
            Issue.record("the approved call should have been dispatched")
            return
        }

        let parent = try #require(try store.ledger.run(id: blocked.id))
        #expect(parent.acknowledgedAt != nil, "approving is a stronger acknowledgement than Dismiss")
        #expect(try store.ledger.unacknowledgedFailures().contains { $0.id == blocked.id } == false,
                "an approved run that ran does not stay in /jobs's failure list")
    }
}
