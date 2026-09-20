import Foundation
import SwiftUI

enum ChatRole: String, Codable, Sendable, Equatable {
    case user
    case agent
    case system
    /// Deterministic slash-command output rendered as Markdown, not attributed to Iris.
    case command
}

struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    let role: ChatRole
    var content: String
    var attachments: [FileAttachment] = []

    enum CodingKeys: String, CodingKey {
        case id, role, content, attachments
    }

    init(id: UUID = UUID(), role: ChatRole, content: String, attachments: [FileAttachment] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(ChatRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        attachments = try container.decodeIfPresent([FileAttachment].self, forKey: .attachments) ?? []
    }
}

struct TokenUsage: Codable, Equatable, Sendable {
    var promptTokenCount: Int = 0
    var candidatesTokenCount: Int = 0
    var totalTokenCount: Int = 0
}

struct Conversation: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var messages: [ChatMessage] = []
    var workspacePath: String?
    var history: [Content] = []
    var tokenUsage: TokenUsage = TokenUsage()
    var activeGoal: String?
    var messageCountSinceReflection: Int = 0
    var goalIterationCount: Int = 0
    var mainAgentSandbox: SandboxPref? = nil
    var isSubagent: Bool = false
    var goalContract: GoalContract? = nil
    var lastGoalCompletionReport: JSONValue? = nil
    var lastGoalEvaluation: GoalEvaluation? = nil
    var subagentResult: SubagentResult? = nil

    init(id: UUID = UUID(), title: String, messages: [ChatMessage] = [], workspacePath: String? = nil, history: [Content] = [], tokenUsage: TokenUsage = TokenUsage(), activeGoal: String? = nil, messageCountSinceReflection: Int = 0, goalContract: GoalContract? = nil) {
        self.id = id
        self.title = title
        self.messages = messages
        self.workspacePath = workspacePath
        self.history = history
        self.tokenUsage = tokenUsage
        self.activeGoal = activeGoal
        self.messageCountSinceReflection = messageCountSinceReflection
        self.goalContract = goalContract
    }

    enum CodingKeys: String, CodingKey {
        case id, title, messages, workspacePath, history, tokenUsage, activeGoal, messageCountSinceReflection, mainAgentSandbox, isSubagent, goalContract, lastGoalCompletionReport, lastGoalEvaluation, subagentResult
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath)
        history = try container.decodeIfPresent([Content].self, forKey: .history) ?? []
        tokenUsage = try container.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage) ?? TokenUsage()
        activeGoal = try container.decodeIfPresent(String.self, forKey: .activeGoal)
        messageCountSinceReflection = try container.decodeIfPresent(Int.self, forKey: .messageCountSinceReflection) ?? 0
        mainAgentSandbox = try container.decodeIfPresent(SandboxPref.self, forKey: .mainAgentSandbox)
        isSubagent = try container.decodeIfPresent(Bool.self, forKey: .isSubagent) ?? false
        goalContract = try container.decodeIfPresent(GoalContract.self, forKey: .goalContract)
        lastGoalCompletionReport = try container.decodeIfPresent(JSONValue.self, forKey: .lastGoalCompletionReport)
        lastGoalEvaluation = try container.decodeIfPresent(GoalEvaluation.self, forKey: .lastGoalEvaluation)
        subagentResult = try container.decodeIfPresent(SubagentResult.self, forKey: .subagentResult)
        // Migration: a legacy conversation that had a goal (activeGoal) but no contract is
        // upgraded to a locked single-qualitative-criterion contract so in-flight goals survive.
        if goalContract == nil, let legacy = activeGoal {
            var c = GoalContract(objective: legacy,
                                 criteria: [Criterion(text: legacy, kind: .qualitative, check: nil)])
            c.lock()
            goalContract = c
        }
        if let gc = goalContract { goalContract = gc.normalizedLadder() }
    }
    
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct ToolApprovalRequest: Identifiable {
    let id = UUID()
    let toolName: String
    let details: String
    let workspace: String?
    let conversationId: UUID?
    let origin: String
    let continuation: CheckedContinuation<Bool, Never>
}

struct ActiveSubagent: Identifiable, Hashable {
    let id: UUID
    let role: String
    let startTime: Date
    var status: String
}

@MainActor
@Observable
class AppState {
    /// The single app-wide AppState. `ChatView` and `SubagentManager` MUST share one instance —
    /// SwiftUI evaluates a `@State`'s default expression on every view re-init, so
    /// `@State var state = AppState()` was constructing several AppStates (each registering itself
    /// as the SubagentManager global and racing on UserDefaults). Referencing the singleton means
    /// the expression returns the same object every time.
    static let shared = AppState()

    var conversations: [Conversation] = []
    var selectedConversationId: UUID?
    /// Read-only for observers. Ownership is centralized through `beginThinking()`/`endThinking()`
    /// so overlapping turns (concurrent sends, subagents, auto-reprompt) can't leave it stuck.
    private(set) var isThinking = false
    /// Transient, per-instance: when set, `requestApproval` auto-approves every tool without
    /// consulting permissions/Vibecop or enqueuing an interactive prompt. Set only by headless
    /// drivers (ScenarioRunner) on their own throwaway AppState — never by the shipping app —
    /// so scenario runs are deterministic and never block on a human. Not persisted.
    var autoApproveTools = false
    /// With `autoApproveTools`, also run the Vibecop evaluation (recording its span) before
    /// approving, so a headless run pays what a real `run_command` pays. The verdict is never
    /// acted on: a benchmark measures the cost, it does not block on it (#135).
    var vibecopUnderAutoApprove = false
    var commandStartTimes: [UUID: Date] = [:]
    var commandDurations: [UUID: TimeInterval] = [:]
    var activeSubagents: [ActiveSubagent] = []
    var subagentWriteLedger: [UUID: [String]] = [:]
    var pendingApprovals: [ToolApprovalRequest] = []
    var availableUpdate: ReleaseInfo?
    var isCheckingForUpdates = false
    var updateCheckStatusMessage: String?
    var onSubagentComplete: [UUID: @Sendable (SubagentTermination) -> Void] = [:]

    /// Fired by the `submit_evaluation` handler in the EVALUATOR's own conversation; the closure
    /// (registered by GoalEvaluator) reconciles the verdict and writes it to the ORIGINATING
    /// conversation. Keyed by the evaluator conversation id. Mirrors `onSubagentComplete`.
    /// `@MainActor`-isolated so the handler can do its bookkeeping directly. It is only ever
    /// invoked from MainActor context (`submit_evaluation`), and typing it that way is what lets
    /// `GoalEvaluator` record the evaluation inline instead of hopping through a detached Task —
    /// which used to defer the write to a later runloop turn (#103).
    var onEvaluationComplete: [UUID: @MainActor @Sendable (JSONValue?) -> Void] = [:]

    /// Reference count of in-flight "thinking" work. `isThinking` is derived from this.
    private var thinkingCount = 0
    /// Tracked UI-initiated tasks so they can be cancelled (e.g. when a conversation is deleted).
    private var activeTasks: [UUID: (conversationId: UUID?, task: Task<Void, Never>)] = [:]

    // MARK: - Mid-turn user messages (#172)

    /// A user message sent while a turn was already running on its conversation. Text-only
    /// entries are handed to the engine at its next model round (`takePendingSteers`); an entry
    /// with attachments, and anything queued behind it, waits and starts a fresh turn when the
    /// running one ends. Starting a second turn instead interleaves two turns on one history,
    /// which the providers answer with empty or rejected responses.
    struct PendingUserMessage: Sendable {
        let text: String
        let attachments: [FileAttachment]
    }
    private var pendingUserMessages: [UUID: [PendingUserMessage]] = [:]

    func hasTurnInFlight(for conversationId: UUID) -> Bool {
        activeTasks.values.contains { $0.conversationId == conversationId }
    }

    func enqueuePendingUserMessage(text: String, attachments: [FileAttachment], for conversationId: UUID) {
        pendingUserMessages[conversationId, default: []].append(PendingUserMessage(text: text, attachments: attachments))
    }

    func pendingUserMessageCount(for conversationId: UUID) -> Int {
        pendingUserMessages[conversationId]?.count ?? 0
    }

    /// The leading text-only entries, removed from the inbox, in arrival order. Stops at the first
    /// entry with attachments so order is preserved. The engine calls this at every model round.
    func takePendingSteers(for conversationId: UUID) -> [String] {
        var queue = pendingUserMessages[conversationId] ?? []
        var taken: [String] = []
        while let first = queue.first, first.attachments.isEmpty {
            taken.append(first.text)
            queue.removeFirst()
        }
        pendingUserMessages[conversationId] = queue.isEmpty ? nil : queue
        return taken
    }

    /// Whatever a finished turn did not consume becomes the next turn: the leading text entries
    /// joined as one message, or the first attachment entry on its own. Runs when a tracked task
    /// completes, so the new turn never overlaps the old one.
    private func drainPendingUserMessages(for conversationId: UUID) {
        guard !hasTurnInFlight(for: conversationId),
              var queue = pendingUserMessages[conversationId], !queue.isEmpty else { return }
        var texts: [String] = []
        while let first = queue.first, first.attachments.isEmpty {
            texts.append(first.text)
            queue.removeFirst()
        }
        let next = texts.isEmpty ? queue.removeFirst() : PendingUserMessage(text: texts.joined(separator: "\n\n"), attachments: [])
        pendingUserMessages[conversationId] = queue.isEmpty ? nil : queue
        startTurn(text: next.text, attachments: next.attachments, in: conversationId)
    }

    /// Empties the inbox and returns how many messages were dropped (Stop, /stop, deletion).
    @discardableResult
    private func discardPendingUserMessages(for conversationId: UUID) -> Int {
        let count = pendingUserMessages[conversationId]?.count ?? 0
        pendingUserMessages[conversationId] = nil
        return count
    }

    /// Test seam: drive `sendMessage` through an engine with a scripted client.
    func installEngine(_ engine: IrisEngine) {
        self.engine = engine
    }

    private var engine: IrisEngine!
    /// Durable conversation persistence (#163). Injected so tests get an in-memory database.
    let store: ConversationStore
    /// Rows `loadConversations()` could not decode on the most recent load (#163). Internal for
    /// the one-time system-line notice below and for tests.
    private(set) var loadedSkippedRows: [SkippedRow] = []

    init(store: ConversationStore = .makeDefault()) {
        self.store = store
        self.engine = IrisEngine(state: self)
        loadConversations()
        if conversations.isEmpty {
            createNewConversation()
        }
        // Every launch notice below goes through `appendLaunchNotice`, which persists it like any
        // other system message but skips it when the same wording is already in the conversation.
        // Several of these conditions recur on every launch until a human intervenes, so dedup by
        // content is what keeps them from stacking up.
        if !loadedSkippedRows.isEmpty, let target = selectedConversationId {
            // Two different things end up in `skipped`, and they need different wording. A bad
            // message/history row belonging to a conversation that still loaded was moved to
            // `quarantine` and the conversation came back without it. Rows belonging to a
            // conversation that is NOT in the load — an unreadable metadata column, a table whose
            // every row failed to decode — were deliberately left untouched on disk, and will be
            // reported again on every launch until someone fixes them.
            let loadedIds = Set(conversations.map(\.id))
            let quarantined = loadedSkippedRows.filter { row in
                guard let id = row.conversationId, loadedIds.contains(id) else { return false }
                return (row.table == "messages" || row.table == "history") && row.ordinal != nil
            }
            let leftInPlace = loadedSkippedRows.filter { row in
                guard let id = row.conversationId, loadedIds.contains(id) else { return true }
                return !((row.table == "messages" || row.table == "history") && row.ordinal != nil)
            }
            if !quarantined.isEmpty {
                let convs = Set(quarantined.compactMap(\.conversationId)).count
                let one = quarantined.count == 1
                appendLaunchNotice("\(quarantined.count) unreadable saved entr\(one ? "y" : "ies") in \(convs) conversation\(convs == 1 ? "" : "s") \(one ? "was" : "were") moved to the quarantine table in \(IrisPaths.default.conversationsDB.lastPathComponent).",
                                   to: target)
            }
            if !leftInPlace.isEmpty {
                // One conversation can contribute more than one row (both its tables unreadable).
                let n = Set(leftInPlace.compactMap(\.conversationId)).count + leftInPlace.filter { $0.conversationId == nil }.count
                appendLaunchNotice("\(n) saved conversation\(n == 1 ? "" : "s") could not be read and \(n == 1 ? "was" : "were") left in place; see the console for details.",
                                   to: target)
            }
        }
        // The legacy UserDefaults blob existed but couldn't be decoded (spec §6): the backup key
        // is already set and the live key already removed (LegacyConversationBlob does both), so
        // this fires exactly once — say so in the app, not just the console log.
        if legacyBlobUndecodable, let target = selectedConversationId {
            appendLaunchNotice("The saved conversations from an earlier version could not be read. A copy was kept in the app settings under a key beginning iris_conversations_backup_.",
                               to: target)
        }
        // The blob decoded fine but the write into the store failed: the live key is left in
        // place by `LegacyConversationBlob` for a retry, so say that instead of "could not be read".
        if legacyBlobImportFailed, let target = selectedConversationId {
            appendLaunchNotice("The saved conversations from an earlier version could not be imported; they will be retried at the next launch.",
                               to: target)
        }
        // `store.loadAll()` itself threw (not a per-row skip): logged in `loadConversations()`;
        // say so here too so the loss is visible, not only in the console log.
        if let headline = loadFailureHeadline, let target = selectedConversationId {
            appendLaunchNotice("Saved conversations could not be loaded (\(headline)). Starting with an empty list; the database was left untouched.",
                               to: target)
        }
    }

    func invalidateEnginePrompt() {
        Task {
            await engine?.invalidateSystemPrompt()
        }
    }
    
    var activeConversationIndex: Int? {
        conversations.firstIndex(where: { $0.id == selectedConversationId })
    }

    // MARK: - Thinking state

    /// Acquire one unit of "thinking". Balanced by `endThinking()`.
    func beginThinking() {
        thinkingCount += 1
        isThinking = true
    }

    /// Release one unit of "thinking".
    func endThinking() {
        thinkingCount = max(0, thinkingCount - 1)
        isThinking = thinkingCount > 0
    }

    /// Runs UI-initiated engine work while holding the thinking indicator and tracking the
    /// task so it can be cancelled. The `work` closure must not touch `isThinking` directly.
    private func runThinkingTask(conversationId: UUID?, _ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        beginThinking()
        let task = Task { @MainActor [weak self] in
            await work()
            guard let self else { return }
            self.activeTasks[id] = nil
            self.endThinking()
            if let conversationId { self.drainPendingUserMessages(for: conversationId) }
        }
        activeTasks[id] = (conversationId, task)
    }

    /// Cancels any tracked tasks associated with a conversation and asks the engine to stop
    /// its auto-reprompt loop for it.
    private func cancelTasks(for conversationId: UUID) {
        // Before the cancelled tasks complete and would drain the inbox into a new turn.
        discardPendingUserMessages(for: conversationId)
        for (_, entry) in activeTasks where entry.conversationId == conversationId {
            entry.task.cancel()
        }
        let engine = self.engine
        Task { await engine?.cancelReprompt(for: conversationId) }
    }

    /// User-initiated interrupt of in-flight work for the active conversation. Bound to the
    /// Esc key / Stop button in the UI. Inert when nothing is running. Cancellation lands at
    /// the engine's next turn boundary (see `IrisEngine.processInput`), which then clears the
    /// thinking indicator via the tracked task's completion.
    func interruptActiveConversation() {
        guard let convId = selectedConversationId, isThinking else { return }
        let dropped = pendingUserMessageCount(for: convId)
        cancelTasks(for: convId)
        let notice = dropped == 0 ? "Interrupted."
            : "Interrupted. \(dropped) queued message\(dropped == 1 ? "" : "s") dropped."
        appendMessage(role: .system, content: notice, to: convId)
    }
    
    func createNewConversation(id: UUID = UUID(), isSubagent: Bool = false) {
        var newConv = Conversation(id: id, title: "New Conversation")
        newConv.isSubagent = isSubagent
        conversations.append(newConv)
        if !isSubagent {
            selectedConversationId = newConv.id
        }
        markChanged(newConv.id, .created)

        Task {
            _ = await HookManager.shared.fireSessionStart(conversationId: newConv.id)
        }
    }
    
    func updateConversationTitle(id: UUID, title: String) {
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].title = title
            markChanged(id, .metadata)
        }
    }
    
    func registerSubagent(id: UUID, role: String) {
        let subagent = ActiveSubagent(id: id, role: role, startTime: Date(), status: "Initializing...")
        activeSubagents.append(subagent)
    }

    func removeSubagent(id: UUID) {
        activeSubagents.removeAll(where: { $0.id == id })
        subagentWriteLedger[id] = nil
    }

    /// Records a successful write_file path for a subagent conversation (deduped). No-op for the
    /// main agent so its writes don't accumulate. Drained into SubagentResult.filesWritten at
    /// termination (spec §5).
    func recordSubagentWrite(conversationId: UUID, path: String) {
        guard conversations.first(where: { $0.id == conversationId })?.isSubagent == true else { return }
        var list = subagentWriteLedger[conversationId] ?? []
        if !list.contains(path) { list.append(path) }
        subagentWriteLedger[conversationId] = list
    }

    /// Returns the recorded writes for a conversation and clears the entry.
    func drainSubagentWrites(for conversationId: UUID) -> [String] {
        let list = subagentWriteLedger[conversationId] ?? []
        subagentWriteLedger[conversationId] = nil
        return list
    }

    /// Persists a subagent's structured result on its conversation for the UI and later slices.
    func setSubagentResult(for conversationId: UUID, _ result: SubagentResult) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[idx].subagentResult = result
        markChanged(conversationId, .metadata)
    }

    func updateSubagentStatus(id: UUID, status: String) {
        if let idx = activeSubagents.firstIndex(where: { $0.id == id }) {
            activeSubagents[idx].status = status
        }
    }
    
    func setWorkspace(for conversationId: UUID, path: String) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].workspacePath = path
            markChanged(conversationId, .metadata)
        }
    }

    /// Bind a contracted goal's workspace at lock (#68), creating it when it does not exist.
    ///
    /// Returns the bound path, or nil when nothing could be bound — creation failing is not fatal:
    /// the goal proceeds unbound, which is exactly today's behaviour and therefore not worse.
    /// `paths` is injected so tests run against a temp root rather than the real ~/.iris.
    @discardableResult
    func bindGoalWorkspace(for conversationId: UUID, contract: GoalContract,
                           paths: IrisPaths = .default) -> String? {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return nil }
        let fm = FileManager.default
        let workspacesRoot = paths.root.appendingPathComponent("workspaces").path

        let resolution = GoalWorkspace.resolve(
            proposed: contract.workspace,
            objective: contract.objective,
            existingBinding: conversations[idx].workspacePath,
            workspacesRoot: workspacesRoot,
            directoryExists: { path in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            })

        switch resolution {
        case .keptExisting(let path):
            return path
        case .existing(let path):
            setWorkspace(for: conversationId, path: path)
            return path
        case .created(let path):
            do {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                appendMessage(role: .system,
                              content: "Could not create a workspace at \(path) (\(error.localizedDescription)). The goal will run in the current directory.",
                              to: conversationId)
                return nil
            }
            setWorkspace(for: conversationId, path: path)
            appendMessage(role: .system, content: "Goal workspace: \(path)", to: conversationId)
            return path
        }
    }

    func setMainAgentSandbox(for conversationId: UUID, pref: SandboxPref?) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].mainAgentSandbox = pref
            markChanged(conversationId, .metadata)
        }
    }

    /// The resolved main-agent sandbox state for a conversation, used by the sidebar toggle's
    /// checkmark. Subagent conversations are not user-togglable, so this is only meaningful for
    /// main conversations.
    func effectiveMainSandboxed(_ conv: Conversation) -> Bool {
        let decision = SandboxPolicy.resolve(
            masterEnabled: ConfigManager.shared.enableSandboxing,
            principal: .main,
            perConversation: conv.mainAgentSandbox,
            perWorkspace: SandboxPolicy.perWorkspaceOverride(workspace: conv.workspacePath),
            globalDefault: ConfigManager.shared.mainAgentSandboxDefault,
            runtimeAvailable: SandboxingManager.shared.isContainerInstalled)
        return decision == .sandboxed
    }

    private func handleSandboxCommand(_ trimmed: String, convId: UUID) {
        guard let conv = conversations.first(where: { $0.id == convId }) else { return }
        let args = trimmed.dropFirst("/sandbox".count).trimmingCharacters(in: .whitespaces)

        // Sub-command: /sandbox workspace <host|sandboxed|clear>
        if args.hasPrefix("workspace") {
            let value = args.dropFirst("workspace".count).trimmingCharacters(in: .whitespaces).lowercased()
            guard let ws = conv.workspacePath else {
                emitCommandOutput("No workspace is linked to this conversation. Link one first (right-click → Link to Workspace…).", format: .markdown, to: convId)
                return
            }
            let success: Bool
            switch value {
            case "host": success = SandboxPolicy.setWorkspaceOverride(.host, for: ws)
            case "sandboxed": success = SandboxPolicy.setWorkspaceOverride(.sandboxed, for: ws)
            case "clear": success = SandboxPolicy.setWorkspaceOverride(nil, for: ws)
            default:
                emitCommandOutput("Usage: `/sandbox workspace host|sandboxed|clear`", format: .markdown, to: convId)
                return
            }
            guard success else {
                emitCommandOutput("Failed to write the per-workspace sandbox setting to `\(ws)` (check permissions).", format: .markdown, to: convId)
                return
            }
            if value == "clear" {
                emitCommandOutput("Cleared the per-workspace main-agent sandbox override for `\(ws)`.", format: .markdown, to: convId)
            } else {
                emitCommandOutput("Per-workspace main-agent sandbox set to **\(value)** for `\(ws)`.", format: .markdown, to: convId)
            }
            return
        }

        // No arg (or anything else): report status.
        let master = ConfigManager.shared.enableSandboxing
        let runtime = SandboxingManager.shared.isContainerInstalled
        let effective = effectiveMainSandboxed(conv)
        let source: String
        if conv.mainAgentSandbox != nil { source = "this conversation" }
        else if SandboxPolicy.perWorkspaceOverride(workspace: conv.workspacePath) != nil { source = "workspace `.iris/sandbox.json`" }
        else { source = "global default" }

        let body = """
        **Sandbox policy**

        - Feature master switch: **\(master ? "on" : "off")**
        - Container runtime installed: **\(runtime ? "yes" : "no")**
        - Main agent (this conversation): **\(effective ? "sandboxed" : "host")** — from \(source)
        - Global default: **\(ConfigManager.shared.mainAgentSandboxDefault.rawValue)**
        - Subagents: **always sandboxed** when the master switch is on and a runtime is present

        Set a per-workspace default with `/sandbox workspace host|sandboxed|clear`.
        """
        emitCommandOutput(body, format: .markdown, to: convId)
    }

    /// Drops the pill-timer entries for a set of messages.
    ///
    /// `commandStartTimes` / `commandDurations` are keyed by message id and are transient (never
    /// persisted), but nothing removed from them — so every `run_command` in a session left an entry
    /// behind that outlived the message it described. Bounded by a single session, and small, but it
    /// grows fastest exactly where sessions run longest: an autonomous goal loop (#100).
    private func purgeCommandTimings(forMessagesIn conversationId: UUID) {
        guard let conv = conversations.first(where: { $0.id == conversationId }) else { return }
        for message in conv.messages {
            commandStartTimes.removeValue(forKey: message.id)
            commandDurations.removeValue(forKey: message.id)
        }
    }

    func deleteConversation(_ id: UUID) {
        cancelTasks(for: id)
        Task { await SandboxSessionManager.shared.endSession(id) }
        purgeCommandTimings(forMessagesIn: id)   // before the messages go — they are the keys
        conversations.removeAll { $0.id == id }
        // Re-point at what the sidebar actually renders (`ChatView` lists non-subagent
        // conversations). Picking `conversations.last` could land the selection on a subagent or
        // evaluator scratch conversation the user cannot see or navigate away from — and
        // `sendMessage` routes by `selectedConversationId`, so the next message would go into a
        // restricted, soon-to-be-deleted conversation (#167).
        if selectedConversationId == id {
            selectedConversationId = conversations.last(where: { !$0.isSubagent })?.id
        }
        markChanged(id, .deleted)
        // Scratch conversations don't count: a list holding only those renders an empty sidebar,
        // so the user still needs somewhere to land. The delete is recorded above either way —
        // `createNewConversation` records its own change and must not swallow this one.
        if !conversations.contains(where: { !$0.isSubagent }) {
            createNewConversation()
        }
    }
    
    func start() {
        Task {
            await engine.start()
        }
    }
    
    func sendMessage(_ text: String, attachments: [FileAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !attachments.isEmpty), let convId = selectedConversationId else { return }
        
        let messageContent = trimmed
        if trimmed.hasPrefix("/goal") {
            let goalText = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if goalText.isEmpty {
                appendMessage(role: .system, content: "Please specify a goal, e.g., `/goal Build a snake game in Python`", to: convId)
                return
            }
            appendMessage(role: .system, content: "Drafting goal contract for: \(goalText)", to: convId)
            let draftPrompt = """
            System Event [Goal Contract Draft]: The user wants to start a goal loop with this goal: "\(goalText)".

            Before starting the loop, use the `propose_goal_contract` tool to draft a structured contract. Produce a concrete, honest definition of "done". Follow the honesty rules in the tool description — do not invent executable checks you cannot actually run. This is a DRAFT for the user to review and edit; the loop does not start until they approve.
            """
            runThinkingTask(conversationId: convId) { [self] in
                await engine.processInput(draftPrompt, source: "System", conversationId: convId)
            }
            return
        } else if trimmed.hasPrefix("/stop") {
            clearGoal(for: convId)
            cancelTasks(for: convId)
            appendMessage(role: .system, content: "Goal mode cancelled.", to: convId)
            return
        } else if trimmed == "/skills" || trimmed.hasPrefix("/skills ") {
            handleSkillsCommand(trimmed, convId: convId)
            return
        } else if trimmed == "/bundle" || trimmed.hasPrefix("/bundle ") {
            handleBundleCommand(trimmed, convId: convId)
            return
        } else if trimmed == "/journey" {
            handleJourneyCommand(convId: convId)
            return
        } else if trimmed == "/rules" || trimmed.hasPrefix("/rules ") {
            handleRulesCommand(trimmed, convId: convId)
            return
        } else if trimmed == "/model" || trimmed.hasPrefix("/model ") {
            handleModelCommand(trimmed, convId: convId)
            return
        } else if trimmed == "/mcp" || trimmed.hasPrefix("/mcp ") {
            handleMcpCommand(trimmed, convId: convId)
            return
        } else if trimmed == "/facts" || trimmed.hasPrefix("/facts ") {
            handleFactsCommand(trimmed, convId: convId)
            return
        } else if trimmed == "/search" || trimmed.hasPrefix("/search ") {
            handleSearchCommand(trimmed, convId: convId)
            return
        } else if trimmed == "/tokens" || trimmed == "/stats" {
            handleTokensCommand(convId: convId)
            return
        } else if trimmed == "/new" {
            createNewConversation()
            return
        } else if trimmed == "/clear" {
            handleClearCommand(convId: convId)
            return
        } else if trimmed == "/update" {
            handleUpdateCommand(convId: convId)
            return
        } else if trimmed == "/sandbox" || trimmed.hasPrefix("/sandbox ") {
            handleSandboxCommand(trimmed, convId: convId)
            return
        } else if trimmed.hasPrefix("/reflect") {
            appendMessage(role: .system, content: "Triggering manual memory reflection...", to: convId)
            let reflectionPrompt = """
            System Event [Reflection Trigger]: It's time to consolidate your memories. Reflect on the recent conversation. Have you learned any new user preferences, project structures, or recurring workflows? If so, use `update_soul` to evolve your persona, `update_user_profile` to update the user profile, `update_memory` to consolidate durable facts, and `create_skill`/`update_skill` for procedural skills. When you learn something durable — a lesson, recipe, decision, or reusable artifact — archive it to your permanent library at `~/.iris/memory/library/` (see your Library Management skill).

            Additionally, perform a grooming pass on your Markdown memory library. Ensure ALL memory files (`~/.iris/memory/skills/*`, `~/.iris/memory/USER.md`, `~/.iris/memory/SOUL.md`) use the Open Knowledge Format (OKF). This means each file MUST start with a YAML frontmatter block containing at least:
            ---
            type: [skill|profile|core|etc]
            title: ...
            description: ...
            tags: [..., ...]
            timestamp: ...
            ---
            Verify that your cross-links between files are still valid, and reorganize or fix any broken links. Output a transparent summary of the gist of the updates and grooming performed for the user. If nothing needs updating, just reply 'No memory consolidation needed at this time.'
            """
            runThinkingTask(conversationId: convId) { [self] in
                await engine.processInput(reflectionPrompt, source: "System", conversationId: convId)
            }
            return
        } else if trimmed.hasPrefix("/vibecop init") {
            appendMessage(role: .system, content: "Initializing Vibecop Guardian mode...", to: convId)
            let initPrompt = "System Event [Vibecop Init]: Analyze the current workspace directory to understand the project structure, language, framework, and tooling. Generate a custom Guardian prompt that defines what terminal commands and file operations are 'routine' for this specific workspace, and what should be escalated to the user. Write this prompt to a new file at `.iris/vibecop.md` inside the workspace using the `write_file` tool. Output a transparent summary of the generated rules for the user."
            runThinkingTask(conversationId: convId) { [self] in
                await engine.processInput(initPrompt, source: "System", conversationId: convId)
            }
            return
        } else if trimmed.hasPrefix("/rename") {
            appendMessage(role: .system, content: "Triggering automatic conversation rename...", to: convId)
            let renamePrompt = "System Event [Rename Trigger]: Evaluate the conversation history and use the `rename_conversation` tool to assign a short, descriptive title (1-4 words) that captures the true gist of this conversation."
            runThinkingTask(conversationId: convId) { [self] in
                await engine.processInput(renamePrompt, source: "System", conversationId: convId)
            }
            return
        }

        appendMessage(role: .user, content: messageContent, attachments: attachments, to: convId)

        // A turn is already running on this conversation: the message steers it (text) or
        // follows it (attachments) instead of starting a second, interleaved turn (#172).
        if hasTurnInFlight(for: convId) {
            enqueuePendingUserMessage(text: messageContent, attachments: attachments, for: convId)
            return
        }
        startTurn(text: messageContent, attachments: attachments, in: convId)
    }

    /// Runs one user message as a turn: attachment processing, the engine call, and the
    /// reflection/rename triggers. The user bubble is already in the chat.
    private func startTurn(text: String, attachments: [FileAttachment], in convId: UUID) {
        if let idx = conversations.firstIndex(where: { $0.id == convId }) {
            conversations[idx].messageCountSinceReflection += 1
            markChanged(convId, .metadata)
            
            let userMessagesCount = conversations[idx].messages.filter { $0.role == .user }.count
            let shouldRename = userMessagesCount == 3 && conversations[idx].messageCountSinceReflection == 3
            let shouldReflect = conversations[idx].messageCountSinceReflection >= 30
            if shouldReflect {
                conversations[idx].messageCountSinceReflection = 0
                markChanged(convId, .metadata)
            }

            let attachmentsToProcess = attachments
            let rawContent = text
            
            runThinkingTask(conversationId: convId) { [self] in
                var promptForEngine = rawContent
                var inlineParts: [Part] = []

                if !attachmentsToProcess.isEmpty {
                    let primaryModel = ConfigManager.shared.getModel(for: .medium)
                    let primarySupportsVision = VisionRouter.isVisionCapable(modelName: primaryModel)
                    let processed = (try? await AttachmentProcessor.process(attachments: attachmentsToProcess, primarySupportsVision: primarySupportsVision)) ?? AttachmentProcessingResult()

                    for warning in processed.warnings {
                        appendMessage(role: .system, content: "⚠️ \(warning)", to: convId)
                    }

                    var textParts: [String] = []
                    if !rawContent.isEmpty {
                        textParts.append(rawContent)
                    }
                    if !processed.extractedPromptText.isEmpty {
                        textParts.append(processed.extractedPromptText)
                    }

                    if !primarySupportsVision {
                        let visionResult = await VisionRouter.processTextOnlyImages(attachments: attachmentsToProcess)
                        if !visionResult.descriptionText.isEmpty {
                            textParts.append(visionResult.descriptionText)
                        }
                        for warning in visionResult.warnings {
                            appendMessage(role: .system, content: "⚠️ \(warning)", to: convId)
                        }
                    }

                    promptForEngine = textParts.joined(separator: "\n\n")
                    inlineParts = processed.inlineParts
                }

                await engine.processInput(promptForEngine, source: "UI", conversationId: convId, inlineParts: inlineParts)

                if shouldReflect {
                    if let idx = conversations.firstIndex(where: { $0.id == convId }) {
                        conversations[idx].messageCountSinceReflection = 0
                        markChanged(convId, .metadata)
                    }
                    let reflectionPrompt = "System Event [Reflection Trigger]: It's time to consolidate your memories. Reflect on the recent conversation. Have you learned any new user preferences, project structures, or recurring workflows? If so, use `update_soul` to evolve your persona, `update_user_profile` to update the user profile, `update_memory` to consolidate durable facts, and `create_skill`/`update_skill` for procedural skills. When you learn something durable — a lesson, recipe, decision, or reusable artifact — archive it to your permanent library at `~/.iris/memory/library/` (see your Library Management skill). Output a transparent summary of the gist of the updates for the user. If nothing needs updating, just reply 'No memory consolidation needed at this time.'"
                    appendMessage(role: .system, content: "Triggering automatic memory reflection...", to: convId)
                    await engine.processInput(reflectionPrompt, source: "System", conversationId: convId)
                } else if shouldRename {
                    let renamePrompt = "System Event [Rename Trigger]: Evaluate the conversation history and use the `rename_conversation` tool to assign a short, descriptive title (1-4 words) that captures the true gist of this conversation."
                    appendMessage(role: .system, content: "Triggering automatic conversation rename...", to: convId)
                    await engine.processInput(renamePrompt, source: "System", conversationId: convId)
                }
            }
        } else {
            runThinkingTask(conversationId: convId) { [self] in
                await engine.processInput(text, source: "UI", conversationId: convId)
            }
        }
    }
    
    /// How a slash command's direct output is rendered. All command output is display-only —
    /// it is never added to the LLM `history` the agent sees on later turns.
    enum CommandOutputFormat {
        /// Monospaced "System Event" styling (plain text, no Markdown).
        case system
        /// Rendered Markdown, not attributed to Iris.
        case markdown
    }

    /// Emit deterministic slash-command output into the conversation for display only.
    /// This is the sugar slash-command handlers use instead of reaching for `appendMessage`
    /// directly, so each command just declares how its output should look.
    func emitCommandOutput(_ text: String, format: CommandOutputFormat, to conversationId: UUID) {
        let role: ChatRole = format == .markdown ? .command : .system
        appendMessage(role: role, content: text, to: conversationId)
    }

    /// Every message appended here is recorded for persistence, with no opt-out: the store keys
    /// message rows by their index in this array, so a message held in memory without a row shifts
    /// every ordinal after it. On the next launch it is absent, the indices shift back, and the
    /// first append `INSERT OR REPLACE`s the previous session's last message (review finding, #163
    /// round 3 — a `persist: false` launch notice did exactly this). Anything that must not
    /// accumulate is de-duplicated at the point of appending; see `appendLaunchNotice`.
    func appendMessage(role: ChatRole, content: String, attachments: [FileAttachment] = [], id: UUID = UUID(), to conversationId: UUID) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].messages.append(ChatMessage(id: id, role: role, content: content, attachments: attachments))

            // Auto-title generation based on first message
            if role == .user && conversations[idx].messages.filter({ $0.role == .user }).count == 1 {
                let displayTitle = content.isEmpty ? (attachments.first?.filename ?? "Attachment") : content
                conversations[idx].title = String(displayTitle.prefix(30)) + (displayTitle.count > 30 ? "..." : "")
                markChanged(conversationId, .metadata)
            }
            markChanged(conversationId, .messagesAppended(from: conversations[idx].messages.count - 1))
        }
    }

    /// A launch-time system line, persisted like any other message but written at most once per
    /// distinct wording. Several of the conditions that raise one recur on every launch until a
    /// human intervenes (an unreadable metadata column, a table whose every row failed to decode,
    /// a legacy import that keeps failing), and an unconditional append would stack one copy per
    /// launch. The text is the dedup key on purpose: a changed count is a genuinely different
    /// report and earns its own line.
    func appendLaunchNotice(_ text: String, to conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        guard !conversations[idx].messages.contains(where: { $0.role == .system && $0.content == text }) else { return }
        appendMessage(role: .system, content: text, to: conversationId)
    }
    
    /// Replaces one message's content in place (a streamed reply growing). No title generation;
    /// the caller asks for a save only when the message is final.
    func updateMessageContent(id: UUID, content: String, in conversationId: UUID, persist: Bool = false) {
        guard let c = conversations.firstIndex(where: { $0.id == conversationId }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[c].messages[m].content = content
        if persist { markChanged(conversationId, .messageUpdated(id: id)) }
    }

    func updateHistory(for conversationId: UUID, history: [Content]) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].history = history
            markChanged(conversationId, .historyReplaced)
        }
    }
    
    func appendContentToHistory(for conversationId: UUID, content: Content) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].history.append(content)
            markChanged(conversationId, .historyAppended(from: conversations[idx].history.count - 1))
        }
    }

    /// Strips binary Base64 inlineData from all history entries in a conversation to prevent
    /// token multiplication and disk inflation on subsequent turns.
    func stripInlineDataFromHistory(for conversationId: UUID) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            var updatedHistory = conversations[idx].history
            var modified = false
            for i in 0..<updatedHistory.count {
                for j in 0..<updatedHistory[i].parts.count {
                    if updatedHistory[i].parts[j].inlineData != nil {
                        updatedHistory[i].parts[j].inlineData = nil
                        modified = true
                    }
                }
            }
            if modified {
                conversations[idx].history = updatedHistory
                markChanged(conversationId, .historyReplaced)
            }
        }
    }
    
    func appendContentsToHistory(for conversationId: UUID, contents: [Content]) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].history.append(contentsOf: contents)
            markChanged(conversationId, .historyAppended(from: conversations[idx].history.count - contents.count))
        }
    }
    
    func updateTokenUsage(for conversationId: UUID, usage: UsageMetadata) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].tokenUsage.promptTokenCount += usage.promptTokenCount ?? 0
            conversations[idx].tokenUsage.candidatesTokenCount += usage.candidatesTokenCount ?? 0
            conversations[idx].tokenUsage.totalTokenCount += usage.totalTokenCount ?? 0
            markChanged(conversationId, .metadata)
        }
    }
    
    func clearGoal(for conversationId: UUID) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].activeGoal = nil
            conversations[idx].goalContract = nil
            conversations[idx].goalIterationCount = 0
            markChanged(conversationId, .metadata)
        }
    }

    /// Records the optional per-criterion self-report from a `goal_complete` call.
    /// Must be called BEFORE `clearGoal` so the contract is still present for context.
    func recordCompletionSelfReport(for conversationId: UUID, statusJSON: JSONValue?) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[idx].lastGoalCompletionReport = statusJSON
        markChanged(conversationId, .metadata)
    }

    /// Dismisses the completion self-report chip (the ✕). Independent of `clearGoal` so the
    /// report survives a goal_complete but the user can still put it away without starting a
    /// new goal.
    ///
    /// Refuses while the goal is awaiting judgement: `lastGoalEvaluation` is the ONLY thing the
    /// Accept/Reject buttons act on, and it is also what makes the chip render at all. Dropping it
    /// mid-pause leaves `awaitingHumanJudgement == true` with `activeGoal` set, no chip, no resume
    /// guard that wakes the loop, and no way back in — a goal reachable only through `/stop`. The
    /// guard lives here rather than only in the view so no future caller can re-open the hole; the
    /// chip also hides the ✕ in that state so it is never a visibly dead button.
    func dismissCompletionReport(for conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              conversations[idx].goalContract?.awaitingHumanJudgement != true else { return }
        conversations[idx].lastGoalCompletionReport = nil
        conversations[idx].lastGoalEvaluation = nil
        markChanged(conversationId, .metadata)
    }

    /// Captures the locked contract's criteria as a fresh `.verifying` evaluation BEFORE the goal
    /// is cleared, so the async grader has a snapshot to grade against (spec §3.2). Returns the
    /// snapshot contract for the grader.
    @discardableResult
    func beginGoalEvaluation(for conversationId: UUID, contract: GoalContract) -> GoalContract {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return contract }
        let pending = GoalEvaluation(
            status: .verifying,
            criteria: contract.criteria.map {
                CriterionVerdict(criterionId: $0.id, criterionText: $0.text, kind: $0.kind,
                                 verdict: $0.kind == .humanJudged ? .humanPending : .cannotVerify,
                                 evidence: "", method: $0.kind == .executable ? .check : ($0.kind == .qualitative ? .judge : .human))
            },
            startedAt: Date(), completedAt: nil)
        conversations[idx].lastGoalEvaluation = pending
        markChanged(conversationId, .metadata)
        return contract
    }

    /// Writes a finished evaluation onto the originating conversation (marks it graded/failed).
    func recordEvaluation(for conversationId: UUID, _ evaluation: GoalEvaluation) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[idx].lastGoalEvaluation = evaluation
        markChanged(conversationId, .metadata)
    }

    /// The gate refused completion: bump the attempt count and leave everything else alone. The
    /// goal stays active on purpose, so the existing auto-reprompt carries the agent back to work —
    /// that is the entire retry loop (spec §6).
    func recordGateRefusal(for conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              var c = conversations[idx].goalContract else { return }
        c.gateAttempts += 1
        conversations[idx].goalContract = c
        markChanged(conversationId, .metadata)
    }

    /// Record the agent's `n/a — <reason>` waiver for one criterion. Returns false when the waiver
    /// is not allowed: no locked contract, no failed grade yet (the agent must try before declaring
    /// something inapplicable), an unknown criterion, or a blank reason — the stated reason is the
    /// entire point, since it is what the user sees.
    @discardableResult
    func waiveCriterion(for conversationId: UUID, criterionId: UUID, reason: String) -> Bool {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              var c = conversations[idx].goalContract,
              c.gateAttempts > 0,
              c.criteria.contains(where: { $0.id == criterionId })
        else { return false }
        c.waivers[criterionId] = trimmed
        conversations[idx].goalContract = c
        markChanged(conversationId, .metadata)
        return true
    }

    /// Stamp the gate's verdict onto the recorded evaluation before the goal is cleared.
    /// `clearGoal` nils `goalContract`, so the waiver map has to be copied here or it disappears
    /// exactly when the completion report needs it (spec §5.1).
    func finishGatedGoal(for conversationId: UUID, outcome: GateOutcome, waivers: [UUID: String]) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              var eval = conversations[idx].lastGoalEvaluation else { return }
        eval.gateOutcome = outcome
        eval.waivers = waivers
        conversations[idx].lastGoalEvaluation = eval
        markChanged(conversationId, .metadata)
    }

    /// Record the user's verdict on one `humanJudged` criterion (spec §6).
    ///
    /// Returns false when the judgement does not apply: the goal is not awaiting judgement (a
    /// stale click after `/stop` or completion), the criterion is unknown, or it is not actually
    /// `human_pending` — a second click must not flip a verdict already given.
    ///
    /// `method` stays `.human`, so the row can render "met — your judgement" and never be mistaken
    /// for grader-verified evidence.
    @discardableResult
    func recordHumanJudgement(for conversationId: UUID, criterionId: UUID, accepted: Bool) -> Bool {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              conversations[idx].goalContract?.awaitingHumanJudgement == true,
              var eval = conversations[idx].lastGoalEvaluation,
              let vIdx = eval.criteria.firstIndex(where: {
                  $0.criterionId == criterionId && $0.verdict == .humanPending
              })
        else { return false }

        eval.criteria[vIdx].verdict = accepted ? .met : .notMet
        eval.criteria[vIdx].method = .human
        conversations[idx].lastGoalEvaluation = eval
        // D3: also record it on the contract. `lastGoalEvaluation` is transient — the next
        // `beginGoalEvaluation` overwrites it and `sanitizeLoaded` clears it on load — so a
        // checkpoint re-grade would otherwise reset this criterion to `human_pending` and ask the
        // user for a verdict they already gave (spec §5.1).
        var contract = conversations[idx].goalContract
        contract?.judgements[criterionId] = accepted
        conversations[idx].goalContract = contract
        markChanged(conversationId, .metadata)
        resolveJudgementIfComplete(for: conversationId)
        return true
    }

    /// Once nothing is `human_pending`, act on what the user decided (spec §7).
    ///
    /// The grader is deliberately NOT re-run: its verdicts are already in hand, and a second run
    /// would spend minutes re-deriving them AND overwrite the user's judgement with a fresh
    /// `human_pending`.
    private func resolveJudgementIfComplete(for conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              conversations[idx].goalContract?.awaitingHumanJudgement == true,
              let eval = conversations[idx].lastGoalEvaluation,
              !eval.criteria.contains(where: { $0.verdict == .humanPending })
        else { return }

        conversations[idx].goalContract?.awaitingHumanJudgement = false
        // What the USER rejected — not every `not_met` on the evaluation. A `not_met` the agent
        // waived is excluded from `blockingCriteria`, which is precisely why the pause could fire
        // with one still sitting in `eval.criteria`; counting it here would resume the agent and
        // tell it "you did not meet this, in the user's judgement" about a verdict the user never
        // gave, then pause again on the next `goal_complete` — looping a full grader run per turn
        // until the iteration cap soft-stopped the goal. A third predicate, deliberately not
        // `blockingCriteria` and not `pendingJudgement`: it asks who decided, not what blocks.
        let rejected = eval.criteria.filter { $0.verdict == .notMet && $0.method == .human }

        if rejected.isEmpty {
            // Everything the user was asked about passed, and nothing else was blocking when we
            // paused — so the gate is satisfied.
            let waivers = conversations[idx].goalContract?.waivers ?? [:]
            // Captured before `clearGoal` nils the contract it lives on.
            let summary = conversations[idx].goalContract?.pendingCompletionSummary ?? ""
            finishGatedGoal(for: conversationId, outcome: .passed, waivers: waivers)
            clearGoal(for: conversationId)
            appendMessage(role: .system, content: "Goal complete — your judgement resolved the last criteria.",
                          to: conversationId)
            // Spec §7: the goal "completes exactly as D1 completes it". The `goal_complete` handler
            // returned at the pause, before it could push the summary or run the skill-check
            // reflection, so both happen here instead.
            if !summary.isEmpty {
                appendMessage(role: .agent, content: summary, to: conversationId)
            }
            runThinkingTask(conversationId: conversationId) { [self] in
                await engine.processInput(IrisEngine.goalCompletionSkillCheck, source: "System",
                                          conversationId: conversationId)
            }
        } else {
            // A rejection is something the agent CAN act on. Hand it back with the reasons named.
            // Save here: the flag flip above must land WITH the verdict `recordHumanJudgement`
            // already saved. Skipping this and waiting on `resumeGoalLoop`'s eventual reply would
            // leave a crash/quit window where the disk has the verdict but still says
            // `awaitingHumanJudgement == true` with no human_pending criterion left — a goal no
            // resume guard will wake and no button will render for. That is the exact trapped-goal
            // failure this gate exists to prevent.
            let names = rejected.map { "- \($0.criterionText)" }.joined(separator: "\n")
            // Reset the iteration budget as the checkpoint resumes do: the agent is being sent
            // back to work on something new, and a rejection that lands late in a long run would
            // otherwise soft-stop after a single turn.
            conversations[idx].goalIterationCount = 0
            markChanged(conversationId, .metadata)
            resumeGoalLoop(for: conversationId, framing: .judgementRejection,
                           steer: "You did not meet these, in the user's judgement:\n\(names)")
        }
    }

    /// Park the goal until the user judges its `humanJudged` criteria (spec §4). Deliberately does
    /// NOT touch `gateAttempts`: the agent cannot satisfy these by working, so spending a retry on
    /// them would burn the cap on an outcome it provably cannot change.
    ///
    /// `summary` is the `goal_complete` summary the handler was carrying when it paused. It is
    /// parked on the contract so an accept can push it, since the handler returns here and never
    /// reaches its own push (spec §7).
    func beginJudgementPause(for conversationId: UUID, summary: String = "") {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              var c = conversations[idx].goalContract else { return }
        c.awaitingHumanJudgement = true
        c.pendingCompletionSummary = summary
        conversations[idx].goalContract = c
        markChanged(conversationId, .metadata)
    }

    /// Stores a draft contract on the conversation without locking or touching `activeGoal`.
    /// Called by the `propose_goal_contract` tool handler so the user can review before approval.
    func setDraftContract(for conversationId: UUID, _ draft: GoalContract) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        // Never replace a locked contract with a fresh draft — locked criteria change ONLY
        // through amend_goal_contract (with a rationale). A stray propose_goal_contract during
        // a running goal is ignored.
        if conversations[idx].goalContract?.isLocked == true { return }
        // Starting a new goal clears any prior completion report and evaluation so they don't linger.
        conversations[idx].lastGoalCompletionReport = nil
        conversations[idx].lastGoalEvaluation = nil
        conversations[idx].goalContract = draft
        markChanged(conversationId, .metadata)
    }

    /// Locks a drafted contract onto the conversation and mirrors its objective into `activeGoal`
    /// so the existing loop gate (activeGoal != nil) and #16's machinery keep working unchanged.
    func setGoalContract(for conversationId: UUID, _ contract: GoalContract) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        var locked = contract.normalizedLadder()
        locked.lock()
        conversations[idx].goalContract = locked
        conversations[idx].activeGoal = locked.objective
        conversations[idx].goalIterationCount = 0
        markChanged(conversationId, .metadata)
    }

    /// The only sanctioned edit path for a LOCKED contract. Returns false if rejected
    /// (blank rationale) or no contract. `action` is "add" | "remove" | "update".
    @discardableResult
    func amendGoalContract(for conversationId: UUID, action: String, criterionText: String,
                           kind: String, check: String?, rationale: String) -> Bool {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              var contract = conversations[idx].goalContract else { return false }
        let ck = CriterionKind(rawValue: kind) ?? .qualitative
        let ok = contract.applyCriteriaEdit(rationale: rationale) { criteria in
            switch action {
            case "remove": criteria.removeAll { $0.text == criterionText }
            case "update":
                if let i = criteria.firstIndex(where: { $0.text == criterionText }) {
                    criteria[i].kind = ck; criteria[i].check = ck == .executable ? check : nil
                }
            default: // "add"
                criteria.append(Criterion(text: criterionText, kind: ck, check: ck == .executable ? check : nil))
            }
        }
        if ok {
            conversations[idx].goalContract = contract
            markChanged(conversationId, .metadata)
        }
        return ok
    }

    /// Marks the goal as paused at a checkpoint. Leaves `activeGoal` set so the loop gate is intact;
    /// the engine's auto-reprompt reads `checkpointStatus` and stays quiet (spec §6, §10).
    func setCheckpointPaused(for conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              var c = conversations[idx].goalContract else { return }
        c.checkpointStatus = .pausedForReview
        conversations[idx].goalContract = c
        markChanged(conversationId, .metadata)
    }

    /// Appends one entry to the contract's checkpoint history. All three resolutions are recorded,
    /// so slice F inherits a complete ladder record rather than only the skipped checkpoints.
    /// Caller must already hold a valid index; this does not save (its callers do).
    private func recordCheckpointOutcome(at idx: Int, _ resolution: CheckpointOutcome.Resolution,
                                         evaluation: GoalEvaluation?) {
        guard var c = conversations[idx].goalContract, c.hasLadder,
              c.currentMilestone < c.milestones.count else { return }
        // No evaluation means nothing was graded; record the resolution with an empty one rather
        // than dropping the entry, so the ladder record has no silent gaps.
        let eval = evaluation
            ?? GoalEvaluation(status: .failed, criteria: [], startedAt: Date(), completedAt: Date())
        c.checkpointHistory.append(CheckpointOutcome(
            milestoneIndex: c.currentMilestone,
            milestoneTitle: c.milestones[c.currentMilestone].title,
            evaluation: eval,
            resolution: resolution))
        conversations[idx].goalContract = c
    }

    /// Slice D3 — the grader passed this checkpoint cleanly, so advance without stopping the human.
    ///
    /// Deliberately NOT `advanceCheckpoint`: that one ends in `resumeGoalLoop`, which is right for
    /// a human clicking "Approve & continue" after the turn has ended and wrong here. This runs
    /// inside a live `reach_checkpoint` tool call, so re-arming the reprompt would start a second
    /// loop alongside the turn in flight. The engine's multi-round turn carries the agent forward
    /// on the tool result instead.
    func autoAdvanceCheckpoint(for conversationId: UUID, evaluation: GoalEvaluation?) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              let existing = conversations[idx].goalContract, existing.hasLadder else { return }
        recordCheckpointOutcome(at: idx, .autoAdvanced, evaluation: evaluation)
        guard var c = conversations[idx].goalContract else { return }
        c.currentMilestone = min(c.currentMilestone + 1, c.milestones.count - 1)
        c.checkpointStatus = .running
        conversations[idx].goalContract = c
        conversations[idx].goalIterationCount = 0
        saveConversations()
    }

    /// Human approved the checkpoint: advance to the next milestone and resume the loop.
    func advanceCheckpoint(for conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              conversations[idx].goalContract?.hasLadder == true else { return }
        recordCheckpointOutcome(at: idx, .humanApproved,
                                evaluation: conversations[idx].lastGoalEvaluation)
        guard var c = conversations[idx].goalContract else { return }
        c.currentMilestone = min(c.currentMilestone + 1, c.milestones.count - 1)
        c.checkpointStatus = .running
        conversations[idx].goalContract = c
        conversations[idx].goalIterationCount = 0
        markChanged(conversationId, .metadata)
        resumeGoalLoop(for: conversationId, steer: nil)
    }

    /// Human sent the agent back to keep working the current milestone (no advance).
    func holdCheckpoint(for conversationId: UUID, feedback: String?) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        recordCheckpointOutcome(at: idx, .humanSentBack,
                                evaluation: conversations[idx].lastGoalEvaluation)
        guard var c = conversations[idx].goalContract else { return }
        c.checkpointStatus = .running
        conversations[idx].goalContract = c
        conversations[idx].goalIterationCount = 0
        markChanged(conversationId, .metadata)
        resumeGoalLoop(for: conversationId, steer: feedback)
    }

    /// Why the loop is being re-armed. The two callers are not the same event, and the checkpoint
    /// wording is wrong for the other one: a terminal judgement rejection is not feedback "at this
    /// checkpoint", and the goal it lands on often has no ladder at all.
    enum GoalResumeFraming {
        case checkpoint
        case judgementRejection

        /// How to introduce the human's note.
        var steerHeading: String {
            switch self {
            case .checkpoint:         return "Human feedback at this checkpoint"
            case .judgementRejection: return "The user judged your completion"
            }
        }

        /// What to tell the agent to do next.
        var closingLine: String {
            switch self {
            case .checkpoint:
                return "Continue toward the current checkpoint. What is your next step?"
            case .judgementRejection:
                return "Address that and call `goal_complete` again once it holds. What is your next step?"
            }
        }
    }

    /// Re-arms the goal loop by sending a fresh oracle reprompt — after a checkpoint resume, or
    /// after the user rejected a human-judged criterion at the terminal gate.
    private func resumeGoalLoop(for conversationId: UUID, framing: GoalResumeFraming = .checkpoint,
                                steer: String?) {
        guard let conv = conversations.first(where: { $0.id == conversationId }),
              let contract = conv.goalContract else { return }
        let steerLine = (steer?.isEmpty == false) ? "\n\n\(framing.steerHeading): \(steer!)" : ""
        let reprompt = "\(contract.oracleText())\(steerLine)\n\n\(framing.closingLine)"
        runThinkingTask(conversationId: conversationId) { [self] in
            await engine.processInput(reprompt, source: "System", conversationId: conversationId)
        }
    }

    /// Sends the goal-loop kickoff message for a conversation whose contract is already locked.
    /// Called by `GoalContractPanel` after the user approves the draft.
    func sendGoalKickoff(for conversationId: UUID) {
        guard let conv = conversations.first(where: { $0.id == conversationId }),
              let contract = conv.goalContract else { return }
        let objective = contract.objective
        let kickoff = "GOAL MODE ACTIVATED. Your goal is: \(objective). You must continually use tools to achieve this goal. If you need to stop and think or plan, use the `reflect` tool or just output text. When the goal is COMPLETELY FINISHED, use the `goal_complete` tool."
        runThinkingTask(conversationId: conversationId) { [self] in
            await engine.processInput(kickoff, source: "System", conversationId: conversationId)
        }
    }

    func setGoal(for conversationId: UUID, goal: String) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[idx].activeGoal = goal
            conversations[idx].goalIterationCount = 0
            markChanged(conversationId, .metadata)
        }
    }
    
    enum ApprovalResolution {
        case approve
        case deny
        case alwaysAllowGlobal
        case alwaysAllowProject
    }
    
    func requestApproval(toolName: String, details: String, workspace: String? = nil,
                         conversationId: UUID? = nil, origin: String = "Main agent",
                         inSandbox: Bool = false, callerRole: VibecopCallerRole = .agent,
                         allowedCommands: [String] = [], vibecopEnabled: Bool? = nil) async -> Bool {
        // Headless drivers auto-approve so a scenario run never blocks on a human or a local model.
        if autoApproveTools {
            if vibecopUnderAutoApprove {
                _ = await consultVibecop(toolName: toolName, details: details, workspace: workspace, inSandbox: inSandbox,
                                         callerRole: callerRole, allowedCommands: allowedCommands, vibecopEnabled: vibecopEnabled)
            }
            return true
        }
        // Fast path: deterministic permissions.
        if PermissionManager.shared.isAllowed(toolName: toolName, details: details, workspace: workspace) {
            return true
        }

        if let decision = await consultVibecop(toolName: toolName, details: details, workspace: workspace, inSandbox: inSandbox,
                                               callerRole: callerRole, allowedCommands: allowedCommands, vibecopEnabled: vibecopEnabled) {
            if decision.decision == "APPROVE" { return true }
            if decision.decision == "DENY" { return false }
            // ESCALATE → fall through to the user prompt.
        }

        return await enqueueUserApproval(toolName: toolName, details: details, workspace: workspace,
                                         conversationId: conversationId, origin: origin)
    }

    /// Vibecop, bounded by a timeout so a wedged local model can't hang the turn. nil means the
    /// evaluation failed or timed out (fail open to the user prompt).
    /// Uses adaptive timeout: if the Ollama model is cold (unloaded), give it 30s to load.
    private func consultVibecop(toolName: String, details: String, workspace: String?, inSandbox: Bool,
                                callerRole: VibecopCallerRole, allowedCommands: [String], vibecopEnabled: Bool?) async -> VibecopDecision? {
        do {
            let configuredTimeout = Double(ConfigManager.shared.vibecopTimeoutSeconds)
            let engineType = AuxiliaryEngineType(rawValue: ConfigManager.shared.vibecopEngine) ?? .llamaCPP
            var timeout = configuredTimeout
            
            if engineType == .ollama {
                let engine = try? await AuxiliaryModelManager.shared.getEngine(
                    for: "vibecop", config: AuxiliaryModelConfig(
                        role: "vibecop",
                        engineType: .ollama,
                        modelPathOrName: ConfigManager.shared.vibecopModel
                    )
                )
                if let ollamaEngine = engine, !(await ollamaEngine.isModelLoaded()) {
                    timeout = 30.0  // cold-start budget
                    print("Vibecop: Ollama model cold, using \(timeout)s timeout")
                }
            }
            
            return try await withTimeout(seconds: timeout) {
                try await VibecopService.shared.evaluateAction(toolName: toolName, details: details, workspace: workspace, inSandbox: inSandbox,
                                                               callerRole: callerRole, allowedCommands: allowedCommands, vibecopEnabled: vibecopEnabled)
            }
        } catch {
            // Timeout or Vibecop error → fail open to the user prompt.
            print("Vibecop evaluation failed/timed out: \(error)")
            return nil
        }
    }

    /// Appends an approval request and awaits the user's decision. The queue/continuation seam,
    /// separated from `requestApproval`'s permission/Vibecop fast paths so it is unit-testable.
    func enqueueUserApproval(toolName: String, details: String, workspace: String?,
                             conversationId: UUID?, origin: String) async -> Bool {
        // If our task was already cancelled (e.g. a subagent torn down while we were suspended
        // in the Vibecop/timeout window), do NOT enqueue a request nobody will resolve — the
        // teardown's denyPendingApprovals already ran and would miss a late append.
        if Task.isCancelled { return false }
        return await withCheckedContinuation { continuation in
            pendingApprovals.append(ToolApprovalRequest(
                toolName: toolName, details: details, workspace: workspace,
                conversationId: conversationId, origin: origin, continuation: continuation))
        }
    }

    /// Resolves-false and removes every queued request for a conversation. Used to unstick a
    /// subagent blocked on approval when it is cancelled/timed-out.
    func denyPendingApprovals(for conversationId: UUID) {
        let matching = pendingApprovals.filter { $0.conversationId == conversationId }
        pendingApprovals.removeAll { $0.conversationId == conversationId }
        for req in matching { req.continuation.resume(returning: false) }
    }

    func resolveApproval(_ resolution: ApprovalResolution) {
        guard !pendingApprovals.isEmpty else { return }
        let pending = pendingApprovals.removeFirst()
        var approved = false
        switch resolution {
        case .approve:
            approved = true
        case .deny:
            approved = false
        case .alwaysAllowGlobal:
            PermissionManager.shared.allowGlobally(toolName: pending.toolName, details: pending.details)
            approved = true
        case .alwaysAllowProject:
            if let workspace = pending.workspace {
                PermissionManager.shared.allowInProject(toolName: pending.toolName, details: pending.details, workspace: workspace)
            } else {
                PermissionManager.shared.allowGlobally(toolName: pending.toolName, details: pending.details)
            }
            approved = true
        }
        pending.continuation.resume(returning: approved)
    }
    
    func checkForUpdates(explicit: Bool = false) {
        isCheckingForUpdates = true
        updateCheckStatusMessage = "Checking for updates..."
        Task {
            let result = await UpdateManager.shared.checkForUpdates()
            await MainActor.run {
                self.isCheckingForUpdates = false
                switch result {
                case .updateAvailable(let release):
                    self.availableUpdate = release
                    self.updateCheckStatusMessage = "Update available: \(release.tagName)"
                case .upToDate:
                    self.availableUpdate = nil
                    self.updateCheckStatusMessage = explicit ? "Iris is up to date (v\(Constants.appVersion))." : nil
                case .error(let msg):
                    self.updateCheckStatusMessage = explicit ? "Failed to check for updates: \(msg)" : nil
                }
            }
        }
    }
    
    private var saveTask: Task<Void, Never>? = nil
    /// When the oldest currently-unwritten change arrived; nil when nothing is pending.
    private var firstDirtyAt: Date? = nil
    /// Changes recorded since the last flush, per conversation (spec §3).
    private var pendingChanges: [UUID: ChangeSet] = [:]
    /// The batch a detached write is currently applying. Exactly one at a time; `flushSave`
    /// folds it back into `pendingChanges` so the quit-time write uses current snapshots.
    private var inFlight: [ConversationWrite]? = nil
    /// The detached write applying `inFlight`, kept so `flushSave` can tell it to stand down.
    private var writeTask: Task<Void, Never>? = nil
    /// The stand-down flag the detached write checks under the writer lock. Explicit rather than
    /// `Task.isCancelled`: `apply`'s check runs inside GRDB's synchronous write block, which is
    /// not the detached task's execution context, so the cancellation flag read there belongs to
    /// whatever task (if any) owns that thread — for a `DatabasePool` writer, never the one we
    /// cancelled (review finding, #163 round 2).
    private var writeStandDown: WriteStandDown? = nil

    /// The conversations that belong on disk: durable, user-facing ones only. Sub-process
    /// (subagent / drift-evaluator) scratch conversations are ephemeral and must never persist.
    nonisolated static func durableConversations(_ all: [Conversation]) -> [Conversation] {
        all.filter { !$0.isSubagent }
    }

    /// Repairs a decoded conversation list at load time: drops any ephemeral sub-process
    /// conversations left by an older build, and clears the transient goal-completion surfacing
    /// (`lastGoalCompletionReport` / `lastGoalEvaluation`).
    ///
    /// That surfacing drives the completion "drift chip" above the composer — a per-session,
    /// dismissable affordance, not durable history. Resurrecting last session's chip on the next
    /// launch is both semantically wrong and the trigger for a window-blanking render bug when the
    /// chip auto-appears at startup, so we drop it on load. (The grader is ephemeral anyway, so a
    /// `.verifying` evaluation could never resolve across a restart.)
    nonisolated static func sanitizeLoaded(_ decoded: [Conversation]) -> [Conversation] {
        var loaded = durableConversations(decoded)
        for i in loaded.indices {
            loaded[i].lastGoalCompletionReport = nil
            loaded[i].lastGoalEvaluation = nil
            loaded[i].messages = loaded[i].messages.map(LLMErrorMessage.migrateLegacy)
        }
        return loaded
    }

    /// Quiet period before a debounced save fires.
    static let saveDebounce: TimeInterval = 0.5
    /// Longest a pending change may go unwritten. A trailing-only debounce that cancels its
    /// predecessor on every call never fires at all while mutations keep arriving faster than
    /// the quiet period — and a working goal loop (messages, tool results, token usage, plus a
    /// concurrent drift evaluator) mutates continuously for minutes. That starved the save
    /// indefinitely, so the store held an arbitrarily stale snapshot and a locked goal contract
    /// could lose criteria across a restart (#62). The max wait bounds that staleness.
    static let saveMaxWait: TimeInterval = 2.0

    /// Records one change and schedules a flush with the #62 debounce and max-wait.
    func markChanged(_ id: UUID, _ change: ConversationChange) {
        pendingChanges[id, default: ChangeSet()].add(change)
        let now = Date()
        let dirtySince = firstDirtyAt ?? now
        firstDirtyAt = dirtySince

        // Deadline reached: write now rather than schedule yet another cancellable timer.
        let elapsed = now.timeIntervalSince(dirtySince)
        guard elapsed < Self.saveMaxWait else {
            saveTask?.cancel()
            flush()
            return
        }

        // Otherwise debounce, but never past the deadline.
        saveTask?.cancel()
        let wait = min(Self.saveDebounce, Self.saveMaxWait - elapsed)
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    func pendingChangeSet(for id: UUID) -> ChangeSet? { pendingChanges[id] }

    /// Snapshots the dirty conversations (value copies) and clears the pending set. Sub-process
    /// (subagent / drift-evaluator) conversations are ephemeral scratch and must never persist —
    /// an orphan surviving a mid-run quit would resurrect on the next launch as a normal
    /// main-principal conversation carrying a stale `activeGoal` but WITHOUT its restricted
    /// toolset — so their changes are dropped here.
    ///
    /// The batch is ordered by the conversation's index in `conversations`, because the store
    /// assigns `position` as `MAX(position) + 1` at first insert: taken in `pendingChanges`'
    /// dictionary order, several conversations created inside one debounce window landed on disk
    /// in an arbitrary order and came back in the sidebar shuffled (review finding, #163 round 2).
    /// Deleted and vanished ids sort last; their order among themselves does not matter, but it is
    /// pinned by id so a batch is reproducible.
    private func takeBatch() -> [ConversationWrite] {
        firstDirtyAt = nil
        var order: [UUID: Int] = [:]
        for (index, c) in conversations.enumerated() { order[c.id] = index }
        let batch: [ConversationWrite] = pendingChanges.compactMap { id, changes in
            var changes = changes
            let live = conversations.first { $0.id == id }
            if let live, live.isSubagent { return nil }
            if live == nil && !changes.deleted { return nil }   // vanished without a delete: nothing to write
            // Deleted and re-created inside one window (the same id came back): the conversation
            // is live, so write the current snapshot rather than deleting the row out from under it.
            if live != nil { changes.deleted = false }
            return ConversationWrite(id: id, snapshot: changes.deleted ? nil : live, changes: changes)
        }
        pendingChanges = [:]
        return batch.sorted { lhs, rhs in
            let l = order[lhs.id] ?? Int.max, r = order[rhs.id] ?? Int.max
            return l == r ? lhs.id.uuidString < rhs.id.uuidString : l < r
        }
    }

    /// Re-queues a failed write's changes behind whatever arrived since (spec §3 retry-by-merge).
    private func requeue(_ writes: [ConversationWrite]) {
        guard !writes.isEmpty else { return }
        for w in writes { pendingChanges[w.id, default: ChangeSet()].merge(w.changes) }
        firstDirtyAt = firstDirtyAt ?? Date()
    }

    /// Off-main write of the dirty set. One batch in flight at a time; a batch that arrives
    /// while one is being written waits and is flushed when that write completes.
    private func flush() {
        guard inFlight == nil, !pendingChanges.isEmpty else { return }
        let batch = takeBatch()
        guard !batch.isEmpty else { return }
        inFlight = batch
        let store = self.store
        let standDown = WriteStandDown()
        writeStandDown = standDown
        writeTask = Task.detached(priority: .utility) { [weak self] in
            var failure: Error? = nil
            do { try store.apply(batch, unlessCancelled: { standDown.isSignalled }) } catch { failure = error }
            await MainActor.run {
                guard let self else { return }
                self.inFlight = nil
                if self.writeStandDown === standDown { self.writeStandDown = nil }
                // Whether anything NEW arrived while this batch was being written, sampled before
                // a failure puts the batch back: a durable error (disk full, a corrupt database)
                // would otherwise loop fail → re-queue → flush forever, one log line and one
                // main-actor hop per turn of the spin. A failed batch is logged once and waits for
                // the next `markChanged` or `flushSave` to retry it (spec §3).
                let arrivedDuringWrite = !self.pendingChanges.isEmpty
                if let failure {
                    print("Conversation store write failed; will retry on the next change: \(failure)")
                    // A partial failure already committed everything not listed, so only the
                    // named conversations go back on the queue; anything else means the whole
                    // batch is unaccounted for.
                    if case ConversationStoreError.partialFailure(let failedIds) = failure {
                        let failed = Set(failedIds)
                        self.requeue(batch.filter { failed.contains($0.id) })
                    } else {
                        self.requeue(batch)
                    }
                    if arrivedDuringWrite { self.flush() }
                } else if !self.pendingChanges.isEmpty {
                    self.flush()
                }
            }
        }
    }

    /// Writes everything pending synchronously, right now. `applicationWillTerminate` calls
    /// `_exit(0)` after this, which runs no atexit handlers and would kill the debounce task
    /// and any detached write (#62).
    ///
    /// An in-flight batch is folded back into `pendingChanges` rather than appended to the write,
    /// so every id is written exactly once from its CURRENT snapshot. Appending the in-flight
    /// batch instead would hand `apply` a stale snapshot, and the append paths truncate trailing
    /// rows — a detached write that took the writer lock after this one committed would delete the
    /// very rows we just wrote. The write's `WriteStandDown` flag is signalled (and its task
    /// cancelled) for the same reason; `apply` checks the flag under the writer lock and stands
    /// down. `inFlight` itself is left alone: the detached task's completion clears it.
    func flushSave() {
        saveTask?.cancel()
        writeStandDown?.signal()
        writeTask?.cancel()
        if let inFlight { requeue(inFlight) }
        let batch = takeBatch()
        guard !batch.isEmpty else { return }
        // Nothing to retry with: the process exits immediately after this on the quit path, so a
        // failure here is logged and lost. Every other write retries on the next change.
        do { try store.apply(batch) } catch { print("Conversation store flush failed: \(error)") }
    }
    
    func renameConversation(id: UUID, newTitle: String) {
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].title = newTitle
            markChanged(id, .metadata)
        }
    }
    
    /// Set by `loadConversations()` when the legacy UserDefaults blob existed but could not be
    /// decoded, so `init` can surface it once a conversation exists to attach the notice to.
    private var legacyBlobUndecodable = false
    /// Set by `loadConversations()` when the legacy blob decoded fine but the write into the
    /// store failed (the live key is left in place by `LegacyConversationBlob` for a retry).
    private var legacyBlobImportFailed = false
    /// Set by `loadConversations()` when `store.loadAll()` itself threw (not a per-row skip).
    private var loadFailureHeadline: String? = nil

    private func loadConversations() {
        // One-time move off the UserDefaults blob (spec §6). Cheap when there is no key.
        let outcome = LegacyConversationBlob.migrateIfNeeded(into: store, defaults: IrisDefaults.store)
        if case .imported(let n) = outcome { print("Imported \(n) conversations from the legacy blob.") }
        if outcome == .undecodable { legacyBlobUndecodable = true }
        if outcome == .importFailed { legacyBlobImportFailed = true }

        do {
            let result = try store.loadAll()
            loadedSkippedRows = result.skipped
            let loaded = Self.sanitizeLoaded(result.conversations)
            self.conversations = loaded
            self.selectedConversationId = loaded.last?.id
            // A whole-table corruption can be thousands of rows; one line each would bury
            // everything else in the log.
            let logCap = 10
            for row in result.skipped.prefix(logCap) {
                print("Unreadable \(row.table) row (conversation \(row.conversationId?.uuidString ?? "?"), ordinal \(row.ordinal.map(String.init) ?? "-")): \(row.reason)")
            }
            if result.skipped.count > logCap {
                print("… and \(result.skipped.count - logCap) more unreadable row(s).")
            }
        } catch {
            print("Failed to load conversations: \(error)")
            loadFailureHeadline = "\(error)"
        }
    }

    // MARK: - Slash Command Handlers

    private func handleSkillsCommand(_ trimmed: String, convId: UUID) {
        let args = trimmed.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            guard let self = self else { return }
            if args.hasPrefix("curate") {
                let report = await SkillCurator.shared.curateSkills()
                let markdown = SkillCurator.shared.formatReportMarkdown(report)
                self.emitCommandOutput(markdown, format: .markdown, to: convId)
            } else if args.hasPrefix("new ") {
                let name = String(args.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                let templateBody = """
                # Overview
                Provide a clear summary of when to use this skill.

                # Steps
                1. Step one
                2. Step two

                # Pitfalls & Verification
                - Step verification criteria
                """
                let res = await ToolExecutor.shared.createSkill(
                    name: name,
                    description: "Scaffolded skill '\(name)'",
                    body: templateBody
                )
                self.emitCommandOutput("✨ Scaffolded skill template for **\(name)**.\n\(res)", format: .markdown, to: convId)
            } else if args.hasPrefix("reload") {
                let skillArg = args.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
                await self.engine.invalidateSystemPrompt()
                let skills = await SkillManager.shared.listSkills()
                let body = skillArg.isEmpty
                    ? "Skill definitions reloaded from disk (\(skills.count) active). System prompt cache invalidated."
                    : "Reloaded skill '\(skillArg)'. System prompt cache invalidated."
                self.emitCommandOutput(body, format: .markdown, to: convId)
            } else if args.hasPrefix("show ") || args.hasPrefix("view ") {
                let name = String(args.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let body = await SkillManager.shared.readSkillBody(name: name) {
                    self.emitCommandOutput("### Skill: \(name)\n\n\(body)", format: .markdown, to: convId)
                } else {
                    self.emitCommandOutput("Skill '\(name)' not found.", format: .markdown, to: convId)
                }
            } else {
                let skills = await SkillManager.shared.listSkills()
                let body: String
                if skills.isEmpty {
                    body = "No skills are currently registered."
                } else {
                    let list = skills.map { "- **\($0.name)** — \($0.description)" }.joined(separator: "\n")
                    body = "**Registered skills (\(skills.count))**\n\n\(list)"
                }
                self.emitCommandOutput(body, format: .markdown, to: convId)
            }
        }
    }

    private func handleBundleCommand(_ trimmed: String, convId: UUID) {
        let args = trimmed.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        if args.hasPrefix("save ") {
            let rest = String(args.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = rest.split(separator: " ", maxSplits: 1).map { String($0) }
            guard parts.count == 2 else {
                emitCommandOutput("Usage: `/bundle save <name> skill1,skill2,...`", format: .markdown, to: convId)
                return
            }
            let name = parts[0]
            let skills = parts[1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            let bundle = SkillBundle(name: name, description: "Custom bundle '\(name)'", skillNames: skills)
            do {
                try SkillBundleManager.shared.saveBundle(bundle)
                emitCommandOutput("Saved skill bundle **\(name)** (\(skills.joined(separator: ", "))).", format: .markdown, to: convId)
            } catch {
                emitCommandOutput("Failed to save bundle: \(error.localizedDescription)", format: .markdown, to: convId)
            }
        } else if !args.isEmpty {
            if args == "clear" || args == "off" {
                SkillBundleManager.shared.activeBundle = nil
                Task { [weak self] in
                    await self?.engine.invalidateSystemPrompt()
                    self?.emitCommandOutput("Cleared active skill bundle filter. All registered skills are now loaded.", format: .markdown, to: convId)
                }
            } else if let bundle = SkillBundleManager.shared.getBundle(name: args) {
                SkillBundleManager.shared.activeBundle = bundle
                Task { [weak self] in
                    await self?.engine.invalidateSystemPrompt()
                    self?.emitCommandOutput("Activated skill bundle **\(bundle.name)** (\(bundle.skillNames.joined(separator: ", "))). Context filtered & prompt cache updated.", format: .markdown, to: convId)
                }
            } else {
                emitCommandOutput("Bundle '\(args)' not found. Type `/bundle` to list saved bundles.", format: .markdown, to: convId)
            }
        } else {
            let bundles = SkillBundleManager.shared.listBundles()
            if bundles.isEmpty {
                emitCommandOutput("No skill bundles defined. Use `/bundle save <name> skill1,skill2` to create one.", format: .markdown, to: convId)
            } else {
                var body = "**Defined Skill Bundles (\(bundles.count))**\n\n"
                for b in bundles {
                    body += "• **\(b.name)**: \(b.skillNames.joined(separator: ", "))\n"
                }
                emitCommandOutput(body, format: .markdown, to: convId)
            }
        }
    }

    private func handleJourneyCommand(convId: UUID) {
        Task { [weak self] in
            guard let self = self else { return }
            let items = await JourneyManager.shared.buildTimeline()
            let markdown = JourneyManager.shared.formatTimelineMarkdown(items: items)
            self.emitCommandOutput(markdown, format: .markdown, to: convId)
        }
    }

    private func handleRulesCommand(_ trimmed: String, convId: UUID) {
        let args = trimmed.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            guard let self = self else { return }
            if args == "reload" {
                await self.engine.invalidateSystemPrompt()
                self.emitCommandOutput("Custom rules reloaded from `~/.iris/rules/`. System prompt cache invalidated.", format: .markdown, to: convId)
            } else {
                let custom = await SkillManager.shared.loadCustomRules()
                let body = custom.isEmpty
                    ? "No custom rules found in `~/.iris/rules/`."
                    : "**Active Custom Rules:**\n\(custom)"
                self.emitCommandOutput(body, format: .markdown, to: convId)
            }
        }
    }

    private func handleModelCommand(_ trimmed: String, convId: UUID) {
        let arg = trimmed.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let config = ConfigManager.shared
        if arg.isEmpty {
            let easy = config.getModel(for: .easy)
            let medium = config.getModel(for: .medium)
            let hard = config.getModel(for: .hard)
            let body = """
            **Active Model Configuration**

            - **Easy Tier:** `\(easy)`
            - **Medium Tier (Default):** `\(medium)`
            - **Hard Tier:** `\(hard)`
            """
            emitCommandOutput(body, format: .markdown, to: convId)
        } else {
            Task { [weak self] in
                guard let self = self else { return }
                let newTier: ModelTier?
                if arg == "easy" || arg == "fast" {
                    newTier = .easy
                } else if arg == "medium" {
                    newTier = .medium
                } else if arg == "hard" || arg == "heavy" {
                    newTier = .hard
                } else {
                    newTier = nil
                }

                if let tier = newTier {
                    let modelName = config.getModel(for: tier)
                    await self.engine.invalidateSystemPrompt()
                    self.emitCommandOutput("Active model tier selected: **\(tier.rawValue.capitalized)** (`\(modelName)`).", format: .markdown, to: convId)
                } else {
                    let customModel = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.emitCommandOutput("Custom model '\(customModel)' received. Model configurations are mapped per-tier (`easy`, `medium`, `hard`) in Iris Settings.", format: .markdown, to: convId)
                }
            }
        }
    }

    private func handleMcpCommand(_ trimmed: String, convId: UUID) {
        let arg = trimmed.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            guard let self = self else { return }
            if arg == "reload" {
                await PluginManager.shared.loadAll()
                let pluginConfigs = await PluginManager.shared.mcpConfigs()
                await MCPManager.shared.setPluginConfigs(pluginConfigs)
                await MCPManager.shared.reloadServers()
                let servers = await MCPManager.shared.getServerNames()
                self.emitCommandOutput("MCP servers reloaded (\(servers.count) connected: \(servers.joined(separator: ", "))).", format: .markdown, to: convId)
            } else {
                let servers = await MCPManager.shared.getServerNames()
                let body = servers.isEmpty
                    ? "No MCP servers connected."
                    : "**Connected MCP Servers (\(servers.count)):**\n" + servers.map { "- \($0)" }.joined(separator: "\n")
                self.emitCommandOutput(body, format: .markdown, to: convId)
            }
        }
    }

    private func handleFactsCommand(_ trimmed: String, convId: UUID) {
        let args = trimmed.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
        if args.hasPrefix("probe ") {
            let entity = String(args.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            let facts = (try? FactStoreManager.shared.probe(entity: entity, countsAsRetrieval: false)) ?? []
            let body = facts.isEmpty
                ? "No facts found for entity '\(entity)'."
                : "**Facts for Entity '\(entity)':**\n\n" + facts.map(Self.factLine).joined(separator: "\n")
            emitCommandOutput(body, format: .markdown, to: convId)
        } else if args.hasPrefix("search ") {
            let query = String(args.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            let facts = (try? FactStoreManager.shared.search(query: query, limit: 10, countsAsRetrieval: false)) ?? []
            let body = facts.isEmpty
                ? "No facts found matching '\(query)'."
                : "**Facts matching '\(query)':**\n\n" + facts.map(Self.factLine).joined(separator: "\n")
            emitCommandOutput(body, format: .markdown, to: convId)
        } else if args == "all" {
            let facts = (try? FactStoreManager.shared.listFacts(includeInactive: true, limit: 50)) ?? []
            let body = facts.isEmpty
                ? "FactStore is empty."
                : "**All Facts in FactStore (\(facts.count)):**\n\n" + facts.map(Self.factLine).joined(separator: "\n")
            emitCommandOutput(body, format: .markdown, to: convId)
        } else {
            let facts = (try? FactStoreManager.shared.search(query: "", limit: 10, countsAsRetrieval: false)) ?? []
            let body = facts.isEmpty
                ? "FactStore is empty."
                : "**Recent Facts in FactStore (\(facts.count)):**\n\n" + facts.map(Self.factLine).joined(separator: "\n")
            emitCommandOutput(body, format: .markdown, to: convId)
        }
    }

    /// `/search <query>`: full-text search across every saved conversation (#177). Deterministic
    /// and model-free — the same index `search_memory scope=conversations` reads.
    private func handleSearchCommand(_ trimmed: String, convId: UUID) {
        let query = String(trimmed.dropFirst("/search".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            emitCommandOutput("Usage: `/search <query>`", format: .markdown, to: convId)
            return
        }
        let hits = (try? store.searchConversations(query: query, limit: 10)) ?? []
        let body = hits.isEmpty
            ? "No conversations matching '\(query)'."
            : "**Conversations matching '\(query)':**\n\n"
                + hits.map { "**\($0.title)** \u{2014} \($0.role.rawValue): \($0.snippet)" }.joined(separator: "\n")
        emitCommandOutput(body, format: .markdown, to: convId)
    }

    /// One `/facts` row. The id is shown because the model and the user both need it to call
    /// `manage_fact`; inactive rows carry their lifecycle state.
    static func factLine(_ fact: Fact) -> String {
        let line = "- [\(fact.id)] \(fact.content)"
        switch fact.status {
        case FactStatus.retracted.rawValue:
            return line + " (retracted)"
        case FactStatus.superseded.rawValue:
            return line + " (superseded" + (fact.supersededBy.map { " \u{2192} [\($0)]" } ?? "") + ")"
        default:
            return line
        }
    }

    private func handleTokensCommand(convId: UUID) {
        let usage = conversations.first(where: { $0.id == convId })?.tokenUsage ?? TokenUsage()
        let body = """
        **Token Usage for Current Conversation**

        - **Prompt Tokens:** \(usage.promptTokenCount)
        - **Candidate Tokens:** \(usage.candidatesTokenCount)
        - **Total Tokens Used:** \(usage.totalTokenCount)
        """
        emitCommandOutput(body, format: .markdown, to: convId)
    }

    private func handleClearCommand(convId: UUID) {
        if let idx = conversations.firstIndex(where: { $0.id == convId }) {
            purgeCommandTimings(forMessagesIn: convId)   // before the messages go — they are the keys
            conversations[idx].messages.removeAll()
            markChanged(convId, .messagesReplaced)
            emitCommandOutput("Conversation cleared.", format: .markdown, to: convId)
        }
    }

    private func handleUpdateCommand(convId: UUID) {
        Task { [weak self] in
            guard let self = self else { return }
            let result = await UpdateManager.shared.checkForUpdates()
            let body: String
            switch result {
            case .updateAvailable(let release):
                body = "🎉 **Update available:** [\(release.name)](\(release.htmlUrl))\n\n\(release.body)"
            case .upToDate:
                body = "Iris is up to date (v\(Constants.appVersion))."
            case .error(let err):
                body = "Failed to check for updates: \(err)"
            }
            self.emitCommandOutput(body, format: .markdown, to: convId)
        }
    }
}
