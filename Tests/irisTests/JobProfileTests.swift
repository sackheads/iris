import Testing
import Foundation
@testable import iris

/// #187 deliverable 3, spec §0.2 and §4 "Read-only narrowing": what a `readOnly` job run may not
/// call, that it is never offered those tools in the first place, and that a call reaching the
/// dispatcher anyway fails closed with the whole call recorded — plus the other half of the same
/// decision, that a `mutating` job is creatable again and runs sandboxed with the full surface.
@MainActor
@Suite("job profiles narrow a read-only run (#187)")
struct JobProfileTests {

    // MARK: Fixtures

    private func job(name: String = "sweep",
                     prompt: String = "Reply with just the word tick.",
                     profile: JobProfile = .readOnly) -> Job {
        Job(name: name, prompt: prompt, trigger: .schedule(.interval(seconds: 60)), profile: profile)
    }

    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    private func callResponse(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))],
                       usageMetadata: nil)
    }

    /// A settings store of this suite's own (AGENTS invariant 7): `JobRunner` resolves a job's
    /// limits through a `ConfigManager`, and the default is the process-global one.
    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-jobprofile-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func state() throws -> (ConversationStore, AppState) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let user = UUID()
        state.createNewConversation(id: user)
        state.selectedConversationId = user
        return (store, state)
    }

    /// Fires `job` once through a real runner against `client` and hands back what it left behind.
    private func fire(_ job: Job, client: any LLMClientProtocol, autoApprove: Bool = true,
                      store: ConversationStore, state: AppState) async throws {
        state.autoApproveTools = autoApprove
        let engine = IrisEngine(state: state, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config)
        await runner.fire(job: job, origin: .schedule)
    }

    // MARK: The denylist itself (§0.2)

    @Test("the read-only denylist is exactly what §0.2 settled on")
    func denylistMembership() {
        for name in ["write_file", "edit_file", "create_skill", "update_skill", "delete_skill",
                     "schedule_job", "register_directory_watcher", "send_to_session",
                     "delegate_task", "delegate_milestone", "invoke_subagent"] {
            #expect(JobProfile.readOnlyDenied.contains(name), Comment(rawValue: name))
        }
        for name in ["read_file", "search_web", "search_memory", "list_jobs", "reflect", "goal_complete"] {
            #expect(!JobProfile.readOnlyDenied.contains(name), Comment(rawValue: name))
        }
        // `run_command` is not on the list because its answer depends on where it would run.
        #expect(!JobProfile.readOnlyDenied.contains("run_command"))
    }

    @Test("run_command is allowed to a read-only run only when it is sandboxed")
    func runCommandDependsOnTheSandbox() {
        #expect(!JobProfile.readOnlyDenies("run_command", sandboxedRunCommand: true, readOnlyMCPTools: []))
        #expect(JobProfile.readOnlyDenies("run_command", sandboxedRunCommand: false, readOnlyMCPTools: []))
        #expect(!JobProfile.readOnlyDenies("read_file", sandboxedRunCommand: false, readOnlyMCPTools: []))
        #expect(JobProfile.readOnlyDenies("write_file", sandboxedRunCommand: true, readOnlyMCPTools: []))
    }

    @Test("an MCP tool is denied unless its server marked it read-only")
    func mcpToolsDeniedUnlessMarkedReadOnly() {
        let readOnly: Set<String> = ["github___list_issues"]
        #expect(!JobProfile.readOnlyDenies("github___list_issues", sandboxedRunCommand: false,
                                           readOnlyMCPTools: readOnly))
        #expect(JobProfile.readOnlyDenies("github___create_issue", sandboxedRunCommand: false,
                                          readOnlyMCPTools: readOnly))
        // An MCP tool with nothing said about it at all: denied, not assumed harmless.
        #expect(JobProfile.readOnlyDenies("notion___append_block", sandboxedRunCommand: false,
                                          readOnlyMCPTools: []))
    }

    // MARK: Declaration gating

    @Test("a read-only run is never offered the tools it may not call")
    func readOnlyRunDeclaresANarrowedSurface() async throws {
        let (store, app) = try state()
        let client = CapturingLLMClient(reply: "tick")
        try await fire(job(), client: client, store: store, state: app)

        let names = client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
        #expect(!names.isEmpty, "the run made a model call")
        for denied in ["write_file", "schedule_job", "invoke_subagent", "create_skill",
                       "register_directory_watcher"] {
            #expect(!names.contains(denied), Comment(rawValue: denied))
        }
        for kept in ["read_file", "search_memory"] {
            #expect(names.contains(kept), Comment(rawValue: kept))
        }
    }

    @Test("a mutating run is sandboxed, stamped, and keeps the whole surface")
    func mutatingRunKeepsTheWholeSurface() async throws {
        let (store, app) = try state()
        let client = CapturingLLMClient(reply: "done")
        try await fire(job(name: "tidy", profile: .mutating), client: client, store: store, state: app)

        let background = try #require(app.conversations.first { $0.isBackground })
        #expect(background.mainAgentSandbox == .sandboxed)
        #expect(background.jobProfile == .mutating)
        let names = client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? []
        #expect(names.contains("write_file"))
        #expect(names.contains("read_file"))
    }

    // MARK: Dispatch gating

    @Test("a denied call that reaches the dispatcher blocks the run and records the whole call")
    func deniedCallFailsClosedWithItsArguments() async throws {
        let (store, app) = try state()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-profile-\(UUID().uuidString).txt").path
        // autoApprove is on: what refuses this call is the profile, not the approval path.
        let client = FakeLLMClient(responses: [
            callResponse("write_file", ["path": .string(path), "content": .string("nope")]),
            textResponse("I could not do that."),
        ])
        let job = self.job(name: "wants-to-write")
        try await fire(job, client: client, store: store, state: app)

        #expect(!FileManager.default.fileExists(atPath: path), "the denied call must not have run")

        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .blockedOnApproval)
        #expect(run.blockedTool == "write_file")
        let call = try #require(run.blockedCall)
        #expect(call.reason == .profile)
        #expect(call.args["path"]?.stringValue == path)
        #expect(call.args["content"]?.stringValue == "nope")

        let background = try #require(app.conversations.first { $0.isBackground })
        #expect(background.messages.contains {
            $0.role == .system && $0.content == String(format: AppState.profileDenialNotice, "write_file")
        })

        let activity = try #require(app.conversations.first { $0.id == app.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.first)
        #expect(card.status == .blockedOnApproval)
        #expect(card.blockedTool == "write_file")
    }

    @Test("an approval denial records the call the model sent, not just its name")
    func approvalDenialCarriesTheCall() async {
        let app = AppState()
        let cid = app.createNewConversation(isBackground: true, select: false)

        let approved = await app.requestApproval(toolName: "run_command", details: "rm -rf x",
                                                 args: ["command": .string("rm -rf x")],
                                                 workspace: "/tmp/ws", conversationId: cid)
        #expect(approved == false)
        let denials = app.takeBackgroundDenials(for: cid)
        #expect(denials.count == 1)
        #expect(denials.first?.reason == .approval)
        #expect(denials.first?.args["command"]?.stringValue == "rm -rf x")
        #expect(denials.first?.cwd == "/tmp/ws")
    }

    // MARK: Creating a mutating job

    @Test("a mutating job needs the container runtime, and is created with it")
    func mutatingCreationNeedsTheRuntime() throws {
        let args = try #require(try? ScheduleJobArguments.parse([
            "prompt": .string("tidy the inbox"), "intervalSeconds": .int(3600),
            "profile": .string("mutating"),
        ]).get())

        let refused = args.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [],
                                   runtimeAvailable: false)
        #expect(refused == .failure(ToolMessage(ScheduleJobArguments.noRuntimeForMutating)))

        let made = try args.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [],
                                    runtimeAvailable: true).get()
        #expect(made.profile == .mutating)

        // And the default is still the narrow one.
        let plain = try #require(try? ScheduleJobArguments.parse([
            "prompt": .string("check the queue"), "intervalSeconds": .int(3600),
        ]).get())
        #expect(try plain.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [],
                                  runtimeAvailable: false).get().profile == .readOnly)
    }

    // MARK: Persistence

    @Test("the profile the runner stamps survives a reload")
    func stampedProfileRoundTrips() async throws {
        let (store, app) = try state()
        try await fire(job(name: "persisted"), client: CapturingLLMClient(reply: "tick"),
                       store: store, state: app)
        let background = try #require(app.conversations.first { $0.isBackground })
        #expect(background.jobProfile == .readOnly)

        app.flushSave()
        let reloaded = try store.loadAll().conversations.first { $0.id == background.id }
        #expect(reloaded?.jobProfile == .readOnly)
    }
}
