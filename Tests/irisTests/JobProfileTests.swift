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

    private func tempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-jobprofile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
                      sandboxAvailable: Bool = true,
                      store: ConversationStore, state: AppState) async throws {
        state.autoApproveTools = autoApprove
        let engine = IrisEngine(state: state, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               sandboxAvailable: { sandboxAvailable })
        await runner.fire(job: job, origin: .schedule)
    }

    // MARK: The denylist itself (§0.2)

    @Test("the read-only surface is an allowlist: everything §0.2 named is off it, by default")
    func allowlistMembership() {
        // Everything the spec named, plus the tools a denylist missed: the identity/memory
        // writers, the fact store, and the Google mutators. None of them has to be listed
        // anywhere for this to hold — absence from the allowlist is what denies them.
        for name in ["write_file", "edit_file", "create_skill", "update_skill", "delete_skill",
                     "schedule_job", "register_directory_watcher", "send_to_session",
                     "delegate_task", "delegate_milestone", "invoke_subagent",
                     "update_soul", "update_memory", "update_user_profile",
                     "save_fact", "manage_fact", "set_workspace",
                     "gmail_send_email", "google_calendar_create_event", "google_tasks_create_task",
                     "a_tool_nobody_has_written_yet"] {
            #expect(JobProfile.readOnlyDenies(name, sandboxedRunCommand: true, readOnlyMCPTools: []),
                    Comment(rawValue: name))
            #expect(!JobProfile.readOnlyAllowed.contains(name), Comment(rawValue: name))
        }
        for name in ["read_file", "search_web", "search_memory", "reflect", "list_jobs",
                     "get_job_run", "gmail_list_unread", "google_calendar_list_events"] {
            #expect(!JobProfile.readOnlyDenies(name, sandboxedRunCommand: false, readOnlyMCPTools: []),
                    Comment(rawValue: name))
        }
        // `run_command` is not on the allowlist because its answer depends on where it would run.
        #expect(!JobProfile.readOnlyAllowed.contains("run_command"))
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

    /// The whole declared surface of a real `readOnly` fire, pinned as a set rather than
    /// spot-checked. Spot-checking is what let `update_soul`, `update_memory`,
    /// `update_user_profile` and `save_fact` sit on a read-only run's surface through a review:
    /// each one was simply never named. Anything added to `readOnlyAllowed` from here on has to
    /// change this line, which is the point.
    ///
    /// The two exclusions are guarantees of the test environment, not luck, and must not be read
    /// as fragility: `IrisDefaults` gives a test process its own suite, wiped at process start, so
    /// `ENABLE_SANDBOXING` reads false whatever the developer's real config says and `run_command`
    /// cannot resolve sandboxed (§0.2 then denies it); and `googleRefreshToken` comes through a
    /// `KeychainManager` that is in-memory under tests, so the Google read tools are never
    /// declared at all. Both are pinned directly elsewhere — `runCommandDependsOnTheSandbox` and
    /// `allowlistMembership`.
    @Test("a read-only run is offered exactly the read-only surface, and nothing else")
    func readOnlyRunDeclaresExactlyTheAllowedSurface() async throws {
        let (store, app) = try state()
        let client = CapturingLLMClient(reply: "tick")
        try await fire(job(), client: client, store: store, state: app)

        let names = Set(client.requests.first?.tools?.flatMap { $0.functionDeclarations.map(\.name) } ?? [])
        #expect(names == ["read_file", "search_web", "search_memory", "reflect"])
        // The property behind the equality: whatever a future config change adds to the surface,
        // every name on it has to be one the gate itself allows.
        #expect(names.allSatisfy { !JobProfile.readOnlyDenies($0, sandboxedRunCommand: true,
                                                              readOnlyMCPTools: []) })
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
        // The row says which kind of block it was: nobody can approve this one into running.
        #expect(run.failureReason == "not available to a read-only job: write_file")
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

    @Test("a mutating job needs a resolvable sandbox, and is created with one")
    func mutatingCreationNeedsTheRuntime() throws {
        let args = try #require(try? ScheduleJobArguments.parse([
            "prompt": .string("tidy the inbox"), "intervalSeconds": .int(3600),
            "profile": .string("mutating"),
        ]).get())

        let refused = args.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [],
                                   sandboxAvailable: false)
        #expect(refused == .failure(ToolMessage(ScheduleJobArguments.noRuntimeForMutating)))

        let made = try args.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [],
                                    sandboxAvailable: true).get()
        #expect(made.profile == .mutating)

        // And the default is still the narrow one.
        let plain = try #require(try? ScheduleJobArguments.parse([
            "prompt": .string("check the queue"), "intervalSeconds": .int(3600),
        ]).get())
        #expect(try plain.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [],
                                  sandboxAvailable: false).get().profile == .readOnly)
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

    @Test("a mutating fire with no sandbox to run in is refused, not run on the host")
    func mutatingFireRefusedWithoutASandbox() async throws {
        let (store, app) = try state()
        app.autoApproveTools = true
        let client = FakeLLMClient(responses: [textResponse("I changed things.")])
        let engine = IrisEngine(state: app, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)
        let job = self.job(name: "needs-a-vm", profile: .mutating)
        try store.ledger.upsert(job)
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let runner = JobRunner(state: app, engine: engine, ledger: store.ledger, config: config,
                               sandboxAvailable: { false })

        await runner.fire(job: job, origin: .schedule)

        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .failed)
        #expect(run.failureReason == JobRunner.sandboxUnavailableReason)
        #expect(run.finishedAt != nil)
        #expect(client.callCount == 0, "the turn never started")

        // A failure like any other: the card says so, and the retry ladder applies.
        let activity = try #require(app.conversations.first { $0.id == app.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.first)
        #expect(card.status == .failed)
        #expect(card.outcome?.contains(JobRunner.sandboxUnavailableReason) == true)
        #expect(try store.ledger.jobs().first { $0.id == job.id }?.retryAttempt == 1)
    }

    @Test("a mutating fire with a sandbox runs as before")
    func mutatingFireRunsWhenTheSandboxResolves() async throws {
        let (store, app) = try state()
        let job = self.job(name: "has-a-vm", profile: .mutating)
        try await fire(job, client: CapturingLLMClient(reply: "done"), sandboxAvailable: true,
                       store: store, state: app)
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .completed)
    }

    @Test("a mutating run's command is refused when the VM goes, even with an Always allow rule")
    func unattendedRunCommandNeverFallsBackToTheHost() async throws {
        // R22/R20 on the ordinary fire path. Admission passes (`sandboxAvailable: { true }`), so
        // the job is allowed to start and its conversation is pinned `.sandboxed`; the engine then
        // resolves the host for `run_command` — a container runtime is not available to the test
        // process, exactly as `readOnlyRunDeclaresExactlyTheAllowedSurface` above relies on — which
        // is the mid-turn "the VM went away" case. The user's own "Always allow" rule for this
        // exact command would otherwise be enough to run it on the host, unattended.
        let (store, app) = try state()
        let home = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let permissions = PermissionManager(paths: IrisPaths(root: home))
        let marker = home.appendingPathComponent("ran-on-the-host").path
        let command = "touch \(marker)"
        permissions.allowGlobally(toolName: "run_command", details: command)
        app.permissions = permissions

        let client = FakeLLMClient(responses: [
            callResponse("run_command", ["command": .string(command)]),
            textResponse("I could not run that."),
        ])
        let job = self.job(name: "lost-its-vm", profile: .mutating)
        // autoApprove off: the allowlist rule is what would have let this through.
        try await fire(job, client: client, autoApprove: false, sandboxAvailable: true,
                       store: store, state: app)

        #expect(!FileManager.default.fileExists(atPath: marker),
                "a background command with no container must not run on the host")

        // And the transcript does not first announce a host run that never happens: the guard asks
        // the warning-free predicate, so "running on the host WITHOUT isolation" — true of an
        // attended chat, false of this — is never written above the refusal.
        let background = try #require(app.conversations.first { $0.isBackground })
        #expect(!background.messages.contains { $0.content.contains("WITHOUT isolation") },
                "a refused call must not be preceded by a notice saying it ran on the host")

        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .blockedOnApproval)
        #expect(run.blockedTool == "run_command")
        #expect(run.failureReason == "needs approval: run_command")
        let call = try #require(run.blockedCall)
        // `.approval`, not `.profile`: the click re-asks whether the VM is back, which is the
        // recovery path R20 names.
        #expect(call.reason == .approval)
        #expect(call.args["command"]?.stringValue == command)

        let activity = try #require(app.conversations.first { $0.id == app.activityConversationId() })
        let card = try #require(activity.messages.compactMap { EventCard.decode($0.content) }.first)
        #expect(card.status == .blockedOnApproval)
        #expect(card.blockedTool == "run_command")
        #expect(card.blockedCall?.args["command"]?.stringValue == command)
    }

    @Test("an attended chat with the same Always allow rule still runs the command")
    func anAttendedRunCommandIsUnaffected() async throws {
        // The control for the rule above: it is keyed on the run being unattended, not on the
        // command or the rule, so a person sitting in front of their own chat is not touched.
        let (_, app) = try state()
        let home = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let permissions = PermissionManager(paths: IrisPaths(root: home))
        let marker = home.appendingPathComponent("ran-in-a-chat").path
        let command = "touch \(marker)"
        permissions.allowGlobally(toolName: "run_command", details: command)
        app.permissions = permissions
        app.autoApproveTools = false

        let client = FakeLLMClient(responses: [
            callResponse("run_command", ["command": .string(command)]),
            textResponse("Done."),
        ])
        let engine = IrisEngine(state: app, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)
        let chat = app.createNewConversation(title: "mine")
        app.selectedConversationId = chat

        await engine.processInput("touch it", source: "test", conversationId: chat)

        #expect(FileManager.default.fileExists(atPath: marker),
                "an attended user's own allowlist rule still runs on the host")
        #expect(app.takeBackgroundDenials(for: chat).isEmpty)
    }

    @Test("a profile denial ends the turn instead of being re-asked until the budget runs out")
    func profileDenialEndsTheTurn() async throws {
        let (store, app) = try state()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-profile-loop-\(UUID().uuidString).txt").path
        // The model asks twice; the turn must be over before the second request is ever sent.
        let client = FakeLLMClient(responses: [
            callResponse("write_file", ["path": .string(path), "content": .string("nope")]),
            callResponse("write_file", ["path": .string(path), "content": .string("nope again")]),
            textResponse("fine."),
        ])
        let job = self.job(name: "keeps-asking")
        try await fire(job, client: client, store: store, state: app)

        #expect(client.callCount == 1, "no model round follows a denial that cannot be reversed")
        let background = try #require(app.conversations.first { $0.isBackground })
        let denials = background.messages.filter {
            $0.role == .system && $0.content == String(format: AppState.profileDenialNotice, "write_file")
        }
        #expect(denials.count == 1)
        #expect(background.messages.contains { $0.content.contains(IrisEngine.budgetStopMarker) })
    }

    @Test("two denied calls in one batch: the transcript and the row name the same one")
    func oneStoryForABatchOfDenials() async throws {
        let (store, app) = try state()
        // Both refused, and the batch runs concurrently — so which one is recorded first is a
        // race. Whatever it decides, the line that says why the turn stopped and the row the card
        // is built from have to name the same call, or a person reading one against the other is
        // told two different stories.
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(functionCall: FunctionCall(name: "write_file",
                                                args: ["path": .string("/tmp/a"), "content": .string("x")])),
                Part(functionCall: FunctionCall(name: "create_skill",
                                                args: ["name": .string("s"), "description": .string("d"),
                                                       "body": .string("b")])),
            ]))], usageMetadata: nil),
            textResponse("never reached"),
        ])
        let job = self.job(name: "two-at-once")
        try await fire(job, client: client, store: store, state: app)

        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        let named = try #require(run.blockedTool)
        #expect(["write_file", "create_skill"].contains(named))
        #expect(run.blockedCall?.toolName == named)

        let background = try #require(app.conversations.first { $0.isBackground })
        let stop = try #require(background.messages.last { $0.content.contains(IrisEngine.budgetStopMarker) })
        #expect(stop.content.contains("`\(named)`"))
        // Both refusals are still in the transcript; it is the stop line that must be singular.
        #expect(background.messages.filter { $0.content.hasPrefix("Not run:") }.count == 2)
    }

    @Test("the model is told a read-only job cannot run the tool, not that a user said no")
    func profileRefusalSpeaksForItself() {
        #expect(IrisEngine.profileDeniedToolResult(tool: "write_file").contains("write_file"))
        #expect(IrisEngine.profileDeniedToolResult(tool: "write_file").contains("read-only"))
        #expect(!IrisEngine.profileDeniedToolResult(tool: "write_file").contains("User denied"))
    }

    // MARK: The predicate behind "always in the VM"

    @Test("a mutating job needs the runtime AND the master switch, not either alone")
    func mutatingJobCanRunNeedsBothHalves() {
        // Both call sites inject this in tests, so the production predicate — the whole of the
        // "always runs in the container" claim — is only exercised here. `enableSandboxing` off
        // is the half a denylist-shaped fix missed: `SandboxPolicy.resolve` returns `.host` on it
        // however the conversation is pinned.
        let onName = "iris-jobprofile-on-\(UUID().uuidString)"
        let offName = "iris-jobprofile-off-\(UUID().uuidString)"
        let onStore = UserDefaults(suiteName: onName)!
        let offStore = UserDefaults(suiteName: offName)!
        defer {
            for (name, store) in [(onName, onStore), (offName, offStore)] {
                store.removePersistentDomain(forName: name)
                IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
            }
        }
        let on = ConfigManager(store: onStore)
        on.enableSandboxing = true
        let off = ConfigManager(store: offStore)
        off.enableSandboxing = false

        #expect(SandboxPolicy.mutatingJobCanRun(config: on, runtimeAvailable: true))
        #expect(!SandboxPolicy.mutatingJobCanRun(config: on, runtimeAvailable: false))
        #expect(!SandboxPolicy.mutatingJobCanRun(config: off, runtimeAvailable: true))
        #expect(!SandboxPolicy.mutatingJobCanRun(config: off, runtimeAvailable: false))
    }
}
