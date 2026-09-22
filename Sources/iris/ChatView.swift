import SwiftUI
import MarkdownUI
import UniformTypeIdentifiers

struct ChatView: View {
    @State var state = AppState.shared
    @State private var inputText = ""
    @State private var composerHeight: CGFloat = 24
    @State private var emojiModel = EmojiTokenModel()
    @State private var slashModel = SlashCommandModel()
    @State private var draftAttachments: [FileAttachment] = []
    @State private var isDraggingOver = false
    @State private var selectedMessageIDs = Set<UUID>()
    /// Guards `scrollAfterUpdate` so one SwiftUI update pass enqueues at most one scroll (#183 fix
    /// round 2). See that function's doc comment for why: several `onChange` handlers can fire in
    /// the same pass, and only coalescing to a single, later-evaluated scroll makes the pending
    /// search-reveal target reliably win regardless of which handler happened to run first.
    @State private var scrollPassScheduled = false
    /// Toggled by the toolbar "cpu" badge; drives `SessionStripView`'s collapsed/expanded state.
    /// Replaces the old `SubagentPopoverView` popover (#217 + #19). Not persisted. Starts `true`:
    /// fix round 1's ruling is that the strip defaults to expanded whenever a subagent/evaluator
    /// session exists (a manual collapse is remembered only until the strip empties out, at which
    /// point `SessionStripView` resets this back to `true` itself).
    @State private var sessionStripExpanded = true
    /// Whether the Archived disclosure group is open. The single source of truth: the group
    /// binds to it directly, so the disclosure triangle always does what it looks like it does.
    @State private var archivedExpanded = false

    /// #182 §9: the group auto-expands when the selected conversation *becomes* one of its rows.
    /// Two ways in, and both are a change of the same one value — "the selection, while it is
    /// archived": the selection moves onto an archived row (search reveal, delete re-point,
    /// launch fallback), or the selected conversation is archived where it stands (§8's
    /// `/archive` and the context menu, which change no selection at all). A selected row nobody
    /// can see is the hazard the same-list design exists to dissolve, so both have to open it.
    ///
    /// It is an expand, not a pin: toggling the disclosure triangle does not move the selection
    /// and does not archive anything, so it changes nothing this rule reads and an explicit
    /// collapse sticks until the next genuine trigger. Pulled out of the view so the rule is
    /// testable; the `onChange` that applies it is not.
    static func archivedGroupExpansion(current: Bool, archived: [Conversation],
                                       previousArchivedSelection: UUID?, selection: UUID?) -> Bool {
        guard let selection, selection != previousArchivedSelection,
              archived.contains(where: { $0.id == selection }) else { return current }
        return true
    }

    @State private var showSetupWizard = false
    /// Sidebar conversation search (#183). `sidebarSearchGroups` is republished by the debounced
    /// `.task(id: sidebarQuery)` below rather than computed inline, because the store read it
    /// depends on (`searchConversations`) is synchronous SQLite I/O, not a `View` computation.
    @State private var sidebarQuery = ""
    @State private var sidebarSearchGroups: [SidebarSearchResults.Group] = []
    /// The trimmed query `sidebarSearchGroups` was actually computed for (review finding 3).
    /// While the 200ms debounce is pending for a newer keystroke, this lags behind `sidebarQuery`;
    /// the view uses the mismatch to show nothing rather than an empty-state message for the
    /// query being typed now, or stale groups that belong to the previous one.
    @State private var sidebarSearchedQuery = ""
    @Bindable var config = ConfigManager.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    /// Toggled to true when the composer should grab keyboard focus (e.g. after
    /// creating a new conversation). ComposerTextView reads this in updateNSView
    /// and resets it after making itself first responder.
    @State private var composerShouldFocus = false
    
    private var archivedConversations: [Conversation] {
        SidebarOrdering.archived(state.conversations)
    }

    /// The selected conversation's id, but only while that conversation is archived — nil
    /// otherwise. The single value `archivedGroupExpansion` keys on: it changes when the
    /// selection moves into the group *and* when the selected conversation is archived in place,
    /// and not when the user works the disclosure triangle.
    private var archivedSelection: UUID? {
        guard let id = state.selectedConversationId,
              archivedConversations.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        NavigationSplitView {
            VStack {
                List(selection: $state.selectedConversationId) {
                    let trimmedQuery = sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedQuery.isEmpty {
                        Section(header: Text("Conversations").font(.caption.weight(.bold)).foregroundColor(.secondary).padding(.bottom, 4)) {
                            ForEach(SidebarOrdering.visible(state.conversations)) { conv in
                                conversationRow(conv)
                            }
                        }

                        let archived = archivedConversations
                        if !archived.isEmpty {
                            // A plain binding: the auto-expand is applied by the
                            // `archivedSelection` `onChange` below, not by the getter, so a
                            // collapse is never undone on the next render (#182 §9).
                            DisclosureGroup(isExpanded: $archivedExpanded) {
                                ForEach(archived) { conv in
                                    conversationRow(conv)
                                }
                            } label: {
                                Text("Archived").font(.caption.weight(.bold)).foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Section(header: Text("Results").font(.caption.weight(.bold)).foregroundColor(.secondary).padding(.bottom, 4)) {
                            // While the 200ms debounce is still pending for `trimmedQuery`,
                            // `sidebarSearchGroups` was computed for whatever the *previous*
                            // query was. Showing it (or an empty-state message worded for the
                            // query being typed now) would be wrong in different ways on every
                            // keystroke, so render nothing until they agree (review finding 3).
                            if sidebarSearchedQuery != trimmedQuery {
                                EmptyView()
                            } else if sidebarSearchGroups.isEmpty {
                                Text("No conversations matching \"\(trimmedQuery)\"")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(sidebarSearchGroups) { group in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(group.title)
                                                .font(.subheadline.weight(.semibold))
                                                .lineLimit(1)
                                            // Results replaces both the Conversations and Archived
                                            // sections while a query is active (#212), so this is the
                                            // only place a hit's archive state is visible before the
                                            // user clicks into it.
                                            if state.conversations.first(where: { $0.id == group.conversationId })?.isArchived == true {
                                                Text("Archived")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        ForEach(group.hits, id: \.ordinal) { hit in
                                            Button(action: { state.reveal(hit: hit) }) {
                                                HStack(alignment: .top, spacing: 6) {
                                                    Image(systemName: hit.role == .user ? "person.fill" : "sparkles")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                        .padding(.top, 2)
                                                    Text(hit.snippet)
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                        .lineLimit(2)
                                                        .multilineTextAlignment(.leading)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.leading, 8)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                // Attached to the List rather than the group: the group only exists while
                // something is archived, and the selection can land in it in the same pass that
                // creates it. `onAppear` covers launch, where the restored selection never
                // "changes" (#182 §9). Watching `archivedSelection` rather than the selection
                // alone is what catches archiving the conversation you are looking at, which
                // moves no selection and would otherwise leave you on a row inside a collapsed
                // group.
                .onAppear {
                    archivedExpanded = Self.archivedGroupExpansion(
                        current: archivedExpanded, archived: archivedConversations,
                        previousArchivedSelection: nil, selection: state.selectedConversationId)
                }
                .onChange(of: archivedSelection) { old, _ in
                    archivedExpanded = Self.archivedGroupExpansion(
                        current: archivedExpanded, archived: archivedConversations,
                        previousArchivedSelection: old, selection: state.selectedConversationId)
                }
                .searchable(text: $sidebarQuery, placement: .sidebar, prompt: "Search conversations")
                .task(id: sidebarQuery) {
                    await runSidebarSearch()
                }

                Button(action: { state.createNewConversation(); composerShouldFocus = true }) {
                    HStack {
                        Image(systemName: "plus.message.fill")
                        Text("New Conversation")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .navigationTitle("Iris")
        } detail: {
            if let activeConvIndex = state.activeConversationIndex {
                let conv = state.conversations[activeConvIndex]
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        List(selection: $selectedMessageIDs) {
                            ForEach(groupedMessages(for: conv)) { item in
                                Group {
                                    switch item {
                                    case .single(let message):
                                        MessageView(message: message, state: state,
                                                    transcriptAvailable: EventCard.transcriptAvailable(
                                                        for: message, in: state.conversations))
                                    case .systemGroup(_, let messages):
                                        SystemGroupView(messages: messages, appState: state)
                                    }
                                }
                                .tag(item.id)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .contextMenu {
                                    Button("Copy as Markdown") {
                                        copyMessagesToClipboard(ids: selectedMessageIDs.contains(item.id) ? selectedMessageIDs : [item.id], from: conv, asMarkdown: true)
                                    }
                                    Button("Copy as Text") {
                                        copyMessagesToClipboard(ids: selectedMessageIDs.contains(item.id) ? selectedMessageIDs : [item.id], from: conv, asMarkdown: false)
                                    }
                                }
                            }
                            
                            if state.isThinking {
                                HStack(spacing: 8) {
                                    TypingIndicator()
                                    Text("Iris is thinking...")
                                        .font(.callout)
                                        .foregroundColor(.secondary)

                                    Button(action: { state.interruptActiveConversation() }) {
                                        Label("Stop", systemImage: "stop.circle.fill")
                                            .font(.callout)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.secondary)
                                    .help("Interrupt Iris (Esc)")
                                }
                                .padding(.leading, 12)
                                .padding(.top, 4)
                                .id("thinkingIndicator")
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                            
                            Color.clear.frame(height: 1).id("bottomAnchor")
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        .listStyle(.plain)
                        .defaultScrollAnchor(.bottom)
                        .overlay {
                            if conv.messages.isEmpty {
                                IrisWelcomeView()
                                    .id(conv.id)
                            }
                        }
                        .onCopyCommand {
                            var selectedMessages: [ChatMessage] = []
                            for item in groupedMessages(for: conv) {
                                if selectedMessageIDs.contains(item.id) {
                                    switch item {
                                    case .single(let msg): selectedMessages.append(msg)
                                    case .systemGroup(_, let msgs): selectedMessages.append(contentsOf: msgs)
                                    }
                                }
                            }
                            
                            if selectedMessages.isEmpty { return [] }
                            
                            let format: ChatMessage.ExportFormat =
                                ConfigManager.shared.copyChatsAsMarkdown ? .markdown : .plainText
                            let text = selectedMessages
                                .map { $0.exportLine(format: format) }
                                .joined(separator: "\n\n") + "\n\n"
                            return [NSItemProvider(object: text as NSString)]
                        }
                        .background(Color(NSColor.textBackgroundColor))
                        // Single Escape handler: clear a message selection if there is one,
                        // otherwise fall through to interrupting the agent (a no-op when idle).
                        // This replaced the Stop button's own .cancelAction shortcut so Escape
                        // isn't double-handled.
                        .onExitCommand { handleEscape() }
                        .onChange(of: conv.messages.count) { _, _ in
                            selectedMessageIDs.removeAll()
                            scrollAfterUpdate(proxy)
                        }
                        .onChange(of: conv.messages.last?.content) { _, _ in
                            scrollAfterUpdate(proxy)
                        }
                        .onChange(of: state.isThinking) { _, isThinking in
                            if isThinking {
                                DispatchQueue.main.async {
                                    proxy.scrollTo("thinkingIndicator", anchor: .bottom)
                                }
                            }
                        }
                        // A sidebar search hit (#183) sets `pendingScrollTarget` in the same call
                        // that can also change `selectedConversationId`, so both this handler and
                        // the one below can fire for one reveal. Every site here funnels through
                        // `scrollAfterUpdate`, which always checks the pending target first — no
                        // site does its own unconditional "scroll to bottom", so there is no race
                        // between "which handler's DispatchQueue block runs last" to depend on.
                        .onChange(of: state.activeConversationIndex) { _, _ in
                            selectedMessageIDs.removeAll()
                            scrollAfterUpdate(proxy)
                        }
                        // Covers revealing a hit that belongs to the conversation already open,
                        // where `activeConversationIndex` never changes and the handler above
                        // never fires.
                        .onChange(of: state.pendingScrollTarget) { _, target in
                            guard target != nil else { return }
                            scrollAfterUpdate(proxy)
                        }
                        .onAppear {
                            selectedMessageIDs.removeAll()
                            scrollAfterUpdate(proxy)
                        }
                    }
                    
                    if emojiModel.isShowing {
                        EmojiAutoCompleteView(model: emojiModel)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if slashModel.isShowing {
                        SlashCommandAutoCompleteView(model: slashModel)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if conv.goalContract?.state == .draft {
                        GoalContractPanel(state: state, conversation: conv)
                            .id(conv.goalContract?.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if conv.goalContract?.state == .locked {
                        LockedContractChip(state: state, conversationId: conv.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Top-level pause panel (resume controls). Gated here in ChatView — the same
                    // pattern as CompletionReportChip below, which re-renders reliably on state change.
                    if conv.goalContract?.checkpointStatus == .pausedForReview {
                        CheckpointPauseChip(state: state, conversationId: conv.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // While paused at a checkpoint, the LockedContractChip's pause section already
                    // shows the self-report + verdict, so suppress the standalone chip to avoid a
                    // duplicate. It reappears for a terminal goal_complete (checkpointStatus != paused).
                    if (conv.lastGoalCompletionReport != nil || conv.lastGoalEvaluation != nil),
                       conv.goalContract?.checkpointStatus != .pausedForReview {
                        CompletionReportChip(state: state, conversationId: conv.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    SpectrumLine(active: state.isThinking)

                    // #261: absent, not hidden — a `.hidden()` or a zero-opacity bar would keep
                    // its slot in the stack and give the space back to nothing.
                    if config.showModelLEDs {
                        ModelLEDBar(isThinking: state.isThinking)
                    }

                    messageInputBar

                    SessionStripView(state: state, isExpanded: $sessionStripExpanded)
                }
                .onDrop(of: [.fileURL], isTargeted: $isDraggingOver) { providers in
                    handleDrop(providers: providers)
                }
                .overlay {
                    if isDraggingOver {
                        ZStack {
                            Color.accentColor.opacity(0.12)
                            VStack(spacing: 12) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(.accentColor)
                                Text("Drop files to attach")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                            }
                            .padding(24)
                            .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                            )
                        }
                        .allowsHitTesting(false)
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
                .navigationTitle(conv.title)
                .toolbar {
                    if conv.tokenUsage.totalTokenCount > 0 {
                        ToolbarItem(placement: .automatic) {
                            HStack(spacing: 12) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.circle")
                                    Text("\(conv.tokenUsage.promptTokenCount)")
                                }
                                .foregroundColor(.secondary)
                                .help("Prompt Tokens")
                                
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.circle")
                                    Text("\(conv.tokenUsage.candidatesTokenCount)")
                                }
                                .foregroundColor(.secondary)
                                .help("Candidate Tokens")
                                
                                HStack(spacing: 4) {
                                    Image(systemName: "sum")
                                    Text("\(conv.tokenUsage.totalTokenCount)")
                                }
                                .foregroundColor(.primary)
                                .bold()
                                .help("Total Tokens Used")
                            }
                            .font(.caption)
                        }
                    }
                }
            } else {
                Text("Select or create a conversation.")
                    .foregroundColor(.secondary)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    openWindow(id: "diagnostics")
                }) {
                    Image(systemName: "chart.xyaxis.line")
                }
                .help("Diagnostics")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    withAnimation { sessionStripExpanded.toggle() }
                }) {
                    ZStack {
                        Image(systemName: "cpu")
                        if runningSubagentCount > 0 {
                            Text("\(runningSubagentCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(3)
                                .background(Color.red)
                                .clipShape(Circle())
                                .offset(x: 8, y: -8)
                        }
                    }
                }
                .help("Toggle the session strip")
            }
        }
        // Global approval overlay: floats over the whole window so a request from ANY conversation
        // (incl. a background subagent) is visible without switching tabs. Reads the shared queue.
        .overlay(alignment: .bottom) {
            if let request = state.pendingApprovals.first {
                ApprovalBannerView(request: request,
                                   queueDepth: state.pendingApprovals.count,
                                   onResolve: { resolution in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        state.resolveApproval(resolution)
                    }
                })
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state.pendingApprovals.count)
        .frame(minWidth: 600, idealWidth: 800, minHeight: 400, idealHeight: 600)
        .preferredColorScheme(config.appearanceTheme == "light" ? .light : (config.appearanceTheme == "dark" ? .dark : nil))
        .sheet(isPresented: $showSetupWizard) {
            SetupWizardView()
                .onDisappear {
                    if ConfigManager.shared.isConfigured {
                        state.start()
                    }
                }
        }
        .onAppear {
            let hasCompletedSetup = IrisDefaults.store.bool(forKey: "HAS_COMPLETED_SETUP")
            if !hasCompletedSetup || !ConfigManager.shared.isConfigured {
                showSetupWizard = true
            } else {
                state.start()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RerunSetupWizard"))) { _ in
            showSetupWizard = true
        }
    }
    
    /// Shared row body for both the Conversations and Archived sections, so archiving a
    /// conversation moves it between sections without changing how it renders (#182).
    @ViewBuilder
    private func conversationRow(_ conv: Conversation) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(conv.title)
                    .font(.subheadline)
                    .lineLimit(1)
                if let wp = conv.workspacePath {
                    Text(wp)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .tag(conv.id)
        .contextMenu {
            Button("Link to Workspace...") {
                linkWorkspace(to: conv.id)
            }
            if !conv.isSubagent {
                Toggle("Sandbox main agent", isOn: Binding(
                    get: { state.effectiveMainSandboxed(conv) },
                    set: { state.setMainAgentSandbox(for: conv.id, pref: $0 ? .sandboxed : .host) }
                ))
                .disabled(!ConfigManager.shared.enableSandboxing)
            }
            Button("Export to Markdown...") {
                exportConversation(id: conv.id)
            }
            if conv.isArchived {
                Button("Unarchive") { state.unarchiveConversation(conv.id) }
            } else {
                // The refusal lives in the disabled title (#182 §9.1). The title is computed
                // when the menu is built, though, and a turn can start between that and the
                // click, so the re-check writes the same system line `/archive` does rather
                // than dropping its result on the floor.
                let refusal = state.archiveRefusal(for: conv.id)
                Button(refusal == nil ? "Archive" : "Archive (\(refusal!.reason))") {
                    if let denied = state.archiveConversation(conv.id) {
                        let line = "Cannot archive: \(denied.reason)."
                        // The row right-clicked is usually *not* the conversation on screen, so
                        // writing only into its transcript hides the refusal behind a click the
                        // user has no reason to make. It goes where they are looking, and into
                        // the refused conversation too so its own history records it.
                        state.appendMessage(role: .system, content: line, to: conv.id)
                        if let selected = state.selectedConversationId, selected != conv.id {
                            state.appendMessage(role: .system,
                                                content: "Cannot archive \"\(conv.title)\": \(denied.reason).",
                                                to: selected)
                        }
                    }
                }
                .disabled(refusal != nil)
            }
            Divider()
            Button(role: .destructive, action: {
                state.deleteConversation(conv.id)
            }) {
                Text("Delete Conversation")
                Image(systemName: "trash")
            }
        }
    }

    private func linkWorkspace(to id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Workspace"
        
        if panel.runModal() == .OK, let url = panel.url {
            state.setWorkspace(for: id, path: url.path)
            
            let fm = FileManager.default
            let irisDir = url.appendingPathComponent(".iris")
            let vibecopPath = irisDir.appendingPathComponent("vibecop.md").path
            
            if !fm.fileExists(atPath: vibecopPath) {
                if let contents = try? fm.contentsOfDirectory(atPath: url.path), !contents.isEmpty {
                    state.appendMessage(role: .system, content: "Workspace linked to \(url.path).\n\n💡 Hint: No Vibecop Guardian config found for this workspace. Run `/vibecop init` to generate one.", to: id)
                } else {
                    state.appendMessage(role: .system, content: "Workspace linked to \(url.path).", to: id)
                }
            } else {
                state.appendMessage(role: .system, content: "Workspace linked to \(url.path).", to: id)
            }
        }
    }
    
    private func groupedMessages(for conv: Conversation) -> [MessageItem] {
        MessageItem.group(conv.messages)
    }

    /// Single source of truth for "where does the transcript scroll after this update" (#183
    /// review finding 2, revised in fix round 2). A pending sidebar search-reveal target always
    /// wins over the default scroll-to-bottom, and is cleared once used.
    ///
    /// Revealing a hit in a different conversation changes several observed values in one SwiftUI
    /// update (`selectedConversationId`, `conv.messages.count`/`last?.content` via the new
    /// conversation's own values, `pendingScrollTarget`), so more than one `onChange` handler below
    /// can call this in the same pass. The first version of this fix still called
    /// `DispatchQueue.main.async` from every call site: the first block to run consumed and
    /// cleared `pendingScrollTarget`, so every later block queued in the *same* pass then took the
    /// `else` branch and scrolled to "bottomAnchor" — deterministically landing on the bottom
    /// scroll instead of the centred one, regardless of which handler fired first (reported as a
    /// regression against the reviewer's original ordering-luck finding).
    ///
    /// `scrollPassScheduled` fixes that by coalescing to at most one enqueued block per pass: every
    /// synchronous `onChange` handler for a given SwiftUI update runs before any `DispatchQueue`
    /// block that update enqueues, so by the time the one scheduled block actually runs,
    /// `pendingScrollTarget` already reflects the *pass's* outcome — set if any handler in the pass
    /// resulted from a reveal, nil otherwise — independent of handler firing order.
    private func scrollAfterUpdate(_ proxy: ScrollViewProxy) {
        guard !scrollPassScheduled else { return }
        scrollPassScheduled = true
        DispatchQueue.main.async {
            if let target = state.pendingScrollTarget {
                proxy.scrollTo(target, anchor: .center)
                state.pendingScrollTarget = nil
            } else {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
            scrollPassScheduled = false
        }
    }

    /// Debounced sidebar search (#183): `.task(id: sidebarQuery)` restarts this — and cancels
    /// whatever was in flight — on every keystroke, so the `Task.sleep` below is what keeps a fast
    /// typist from firing a store read per character. The store's read is synchronous SQLite I/O,
    /// which is fine to run inside this task once the debounce has settled it down to one call.
    private func runSidebarSearch() async {
        let trimmed = sidebarQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            sidebarSearchGroups = []
            sidebarSearchedQuery = ""
            return
        }
        do {
            try await Task.sleep(nanoseconds: 200_000_000)
        } catch {
            return   // cancelled by a newer keystroke
        }
        guard !Task.isCancelled else { return }
        let hits = (try? state.store.searchConversations(query: trimmed, limit: 50)) ?? []
        guard !Task.isCancelled else { return }
        // A job run's transcript and a subagent log are out of the sidebar everywhere else
        // (#187); the FTS index still carries them, so they must not come back in through
        // Results. A hit whose conversation is not in memory at all is left alone — `reveal`
        // already handles that miss.
        let hidden = Set(state.conversations.filter { !$0.isUserFacing }.map(\.id))
        sidebarSearchGroups = SidebarSearchResults.group(hits.filter { !hidden.contains($0.conversationId) })
        sidebarSearchedQuery = trimmed
    }
    
    private func exportConversation(id: UUID) {
        guard let conv = state.conversations.first(where: { $0.id == id }) else { return }
        
        // `exportLine` carries the `.system` LLM-error headline substitution this loop used to do
        // inline, plus the `.event` card's transcript line; see `ChatMessage.exportText`.
        var markdown = "# \(conv.title)\n\n"
        for msg in conv.messages {
            markdown += msg.exportLine(format: .markdown) + "\n\n"
        }
        
        let panel = NSSavePanel()
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        
        // Clean title for filename
        let cleanTitle = conv.title.replacingOccurrences(of: " ", with: "_").prefix(30)
        panel.nameFieldStringValue = "\(cleanTitle).md"
        panel.prompt = "Export"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("Failed to save markdown: \(error)")
            }
        }
    }
    
    private func copyMessagesToClipboard(ids: Set<UUID>, from conv: Conversation, asMarkdown: Bool) {
        var selectedMessages: [ChatMessage] = []
        for item in groupedMessages(for: conv) {
            if ids.contains(item.id) {
                switch item {
                case .single(let msg): selectedMessages.append(msg)
                case .systemGroup(_, let msgs): selectedMessages.append(contentsOf: msgs)
                }
            }
        }
        
        guard !selectedMessages.isEmpty else { return }
        
        let format: ChatMessage.ExportFormat = asMarkdown ? .markdown : .plainText
        let text = selectedMessages
            .map { $0.exportLine(format: format) }
            .joined(separator: "\n\n") + "\n\n"
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    private func selectAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        if panel.runModal() == .OK {
            for url in panel.urls {
                let (category, mime) = AttachmentProcessor.categorize(url: url)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                let att = FileAttachment(filename: url.lastPathComponent, fileURL: url, mimeType: mime, fileSize: size, category: category)
                if !draftAttachments.contains(where: { $0.fileURL == url }) {
                    draftAttachments.append(att)
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        DispatchQueue.main.async {
                            let (category, mime) = AttachmentProcessor.categorize(url: url)
                            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                            let att = FileAttachment(filename: url.lastPathComponent, fileURL: url, mimeType: mime, fileSize: size, category: category)
                            if !draftAttachments.contains(where: { $0.fileURL == url }) {
                                draftAttachments.append(att)
                            }
                        }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func submit() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !draftAttachments.isEmpty else { return }
        selectedMessageIDs.removeAll()
        let text = inputText
        let attachments = draftAttachments
        inputText = ""
        draftAttachments = []
        emojiModel.clear()
        slashModel.clear()

        state.sendMessage(text, attachments: attachments)
    }

    /// Escape behavior shared by the message list (`.onExitCommand`) and the composer:
    /// clear a message selection, else interrupt a running turn. Wired to the composer
    /// too because the NSTextView holds focus and would otherwise swallow Escape.
    private func handleEscape() {
        if !selectedMessageIDs.isEmpty {
            selectedMessageIDs.removeAll()
        } else if state.isThinking {
            state.interruptActiveConversation()
        }
    }

    /// The message input bar: a multi-line field (Enter submits, Shift+Enter newlines) + send button.
    /// The toolbar "cpu" badge's count: running subagent/evaluator sessions only (`state.sessions`
    /// never holds the main session — see `AppState.visibleSessions`), matching what
    /// `SessionStripView`'s expanded view lists.
    private var runningSubagentCount: Int {
        state.sessions.filter {
            if case .finished = $0.phase { return false }
            return true
        }.count
    }

    private var messageInputBar: some View {
        let isInputEmpty = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isSendDisabled = isInputEmpty && draftAttachments.isEmpty
        return VStack(spacing: 8) {
            AttachmentBarView(attachments: $draftAttachments)
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: selectAttachments) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Attach Files")
                .padding(.bottom, 8)

                ComposerTextView(text: $inputText, onSubmit: submit, emoji: emojiModel, slash: slashModel, onEscape: handleEscape, onHeightChange: { composerHeight = $0 }, focusTrigger: $composerShouldFocus)
                    .frame(height: min(max(composerHeight, 24), 120))
                    .onAppear { emojiModel.defaultTone = SkinTone(rawValue: config.defaultEmojiSkinTone) ?? .none }
                    .onChange(of: config.defaultEmojiSkinTone) { _, new in
                        emojiModel.defaultTone = SkinTone(rawValue: new) ?? .none
                    }
                    .padding(6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(isSendDisabled ? .secondary : .irisIndigo)
                }
                .buttonStyle(.plain)
                .disabled(isSendDisabled)
                .padding(.bottom, 8)
            }
        }
        .padding()
        .background(.regularMaterial)
    }
}

struct MessageView: View {
    let message: ChatMessage
    /// Only *written* through by the `.event` branch, to open the transcript sheet. Every call
    /// site has an `AppState` in scope; it is a stored property rather than an environment value
    /// because `AppState` is passed explicitly everywhere else in this file. Nothing here reads
    /// observable state off it — see `transcriptAvailable`.
    var state: AppState
    /// Whether this message's event card has a transcript to open, resolved by the list that owns
    /// the message. Read from `state.conversations` in `body` instead, it would subscribe every
    /// event row to the whole conversation array and re-render them on unrelated mutations.
    var transcriptAvailable: Bool = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer()
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .system {
                    HStack {
                        Image(systemName: "gearshape.fill")
                        Text("System Event")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                } else if message.role != .command, message.role != .event {
                    // .command output is deliberately unlabeled (not attributed to Iris), and so
                    // is an .event card — it is a one-line notification, not a turn by anyone.
                    Text(message.role == .user ? "You" : "Iris")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }

                if message.role == .system {
                    SystemMessageContent(text: message.content)
                        .textSelection(.enabled)
                } else if message.role == .user {
                    VStack(alignment: .trailing, spacing: 6) {
                        if !message.attachments.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(message.attachments) { attachment in
                                        AttachmentChipView(attachment: attachment)
                                    }
                                }
                            }
                        }
                        if !message.content.isEmpty {
                            Text(message.content)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(
                                    LinearGradient(
                                        gradient: Gradient(colors: [Color.irisIndigo.opacity(0.55), Color.irisIndigo]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .foregroundColor(textColor)
                                .cornerRadius(12)
                                .cornerRadius(0, corners: [.bottomRight])
                                .shadow(color: Color.irisIndigo.opacity(0.25), radius: 3, x: 0, y: 2)
                        }
                    }
                } else if message.role == .event {
                    if let card = EventCard.decode(message.content) {
                        EventCardView(card: card, onViewRun: viewRunAction(for: card),
                                      onApprove: approveAction(for: card),
                                      onDismiss: dismissAction(for: card))
                    } else {
                        // A card written by a newer build, or a hand-edited row: show the raw
                        // content as plain text rather than running it through Markdown.
                        Text(message.content)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    // Agent messages render via MarkdownUI. We deliberately do NOT apply
                    // `.textSelection(.enabled)` here: on a large Markdown message, MarkdownUI's
                    // layout + SwiftUI text selection form an AttributeGraph cycle that re-fires
                    // on every re-layout (selection, background observable updates), spamming
                    // ~265 "cycle detected" per event (#28). Isolated by bisection: plain Text = 0
                    // cycles, Markdown without textSelection = 0, Markdown WITH textSelection = spam.
                    // Trade-off: no drag-to-select of partial text inside an agent bubble; whole-
                    // message copy still works via row selection + Cmd-C.
                    Markdown(message.content)
                        // Render fenced code blocks WITHOUT MarkdownUI's default horizontal
                        // ScrollView (Theme.basic wraps the label in ScrollView(.horizontal)).
                        // That scroll view swallows trackpad scroll when hovered (#30); wrapping
                        // long lines instead keeps the outer list scrollable everywhere.
                        .markdownBlockStyle(\.codeBlock) { configuration in
                            configuration.label
                                .relativeLineSpacing(.em(0.15))
                                .markdownTextStyle {
                                    FontFamilyVariant(.monospaced)
                                    FontSize(.em(0.94))
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .markdownMargin(top: .zero, bottom: .em(1))
                        }
                        .padding(.vertical, 4)
                }
            }
            
            if message.role != .user {
                Spacer()
            }
        }
    }
    
    /// The "View run" action for a card, or nil when there is no transcript to open — the run
    /// recorded none, or the conversation it recorded has since been pruned. Setting the id on
    /// `AppState` (rather than presenting a sheet from here) keeps one sheet with two openers:
    /// the session strip owns the `.sheet`, on a view that stays mounted while it is up.
    private func viewRunAction(for card: EventCard) -> (() -> Void)? {
        guard transcriptAvailable, let convId = card.transcriptConversationId else { return nil }
        return { state.transcriptSheetConversationId = convId }
    }

    /// The "Approve and run" action, or nil when this card offers no approval — it has no blocked
    /// call, or the call is one no click can authorise (`EventCard.approvalRefusal` is what the
    /// card shows instead). The refusal is re-checked in `JobRunner.runApproved` and again in the
    /// ledger: a card is a snapshot, and this one may have been written by an older build.
    private func approveAction(for card: EventCard) -> (() -> Void)? {
        guard card.offersApproval else { return nil }
        return { state.approveBlockedCall(runId: card.runId) }
    }

    /// The "Dismiss" action — acknowledging the run. Offered only where there is something to
    /// acknowledge, which is the same place the approval half of the card is drawn.
    private func dismissAction(for card: EventCard) -> (() -> Void)? {
        guard card.blockedCall != nil else { return nil }
        return { state.dismissEventCard(runId: card.runId) }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: return Color.accentColor
        case .agent, .command: return Color(NSColor.controlBackgroundColor)
        case .system, .event: return Color(NSColor.windowBackgroundColor).opacity(0.8)
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user: return .white
        case .agent, .system, .command, .event: return .primary
        }
    }

}

struct SystemGroupView: View {
    let messages: [ChatMessage]
    let appState: AppState
    @State private var isExpanded = false

    private var toolCalls: [ToolCallDisplay] {
        messages.compactMap { ToolCallParser.parse($0.content) }
    }
    private var allToolCalls: Bool { !messages.isEmpty && toolCalls.count == messages.count }

    private var headerText: String {
        if allToolCalls {
            return toolCalls.count == 1 ? "1 command" : "\(toolCalls.count) commands"
        }
        return (messages.count > 1 && isExpanded) ? "System Events (\(messages.count))" : "System Event"
    }

    /// Live "current intent": the most recent tool call's intent (or command / name).
    /// If the last message is a non-tool system line, show that line instead. (An LLM error
    /// never reaches here: `MessageItem.group` always gives it a group of its own, and
    /// single-message groups render expanded.)
    private var collapsedStatus: String? {
        guard let last = messages.last else { return nil }
        if let call = ToolCallParser.parse(last.content) {
            return call.intent ?? call.command ?? call.name
        }
        return last.content
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if messages.count > 1 {
                        Button(action: { withAnimation { isExpanded.toggle() } }) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .foregroundColor(.secondary).frame(width: 14)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Spacer().frame(width: 14)
                    }
                    Image(systemName: "gearshape.fill")
                    Text(headerText)
                }
                .font(.callout.weight(.bold))
                .foregroundColor(.secondary)

                if isExpanded || messages.count == 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(messages) { msg in
                            SystemMessageContent(
                                text: msg.content,
                                commandStartTime: appState.commandStartTimes[msg.id],
                                commandDuration: appState.commandDurations[msg.id]
                            )
                            .textSelection(.enabled)
                        }
                    }
                    .padding(.leading, 22)
                } else if let status = collapsedStatus {
                    Text(status)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 22)
                }
            }
            Spacer()
        }
    }
}

struct SystemMessageContent: View {
    let text: String
    var commandStartTime: Date? = nil
    var commandDuration: TimeInterval? = nil
    @State private var isDetailExpanded = false

    var body: some View {
        if let call = ToolCallParser.parse(text) {
            toolCallRow(call, startTime: commandStartTime, duration: commandDuration)
        } else if let error = LLMErrorMessage.parse(text) {
            llmErrorRow(error)
        } else {
            fallbackView
        }
    }

    /// One-line headline; the provider's (capped) raw body is behind a chevron.
    @ViewBuilder
    private func llmErrorRow(_ error: LLMErrorDisplay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(error.headline)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if error.detail != nil {
                    Button(action: { withAnimation { isDetailExpanded.toggle() } }) {
                        Image(systemName: isDetailExpanded ? "chevron.down" : "chevron.right")
                            .foregroundColor(.secondary).frame(width: 14)
                    }
                    .buttonStyle(.plain)
                    .help(isDetailExpanded ? "Hide provider response" : "Show provider response")
                }
            }
            .font(.caption.monospaced())
            if isDetailExpanded, let detail = error.detail {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private func toolCallRow(_ call: ToolCallDisplay, startTime: Date? = nil, duration: TimeInterval? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let command = call.command {
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text("$").foregroundColor(.secondary)
                        Text(command).foregroundColor(.primary)
                    }
                    Spacer()
                    timerLabel(startTime: startTime, duration: duration)
                }
                .font(.caption.monospaced())
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .foregroundColor(.blue).font(.caption2)
                    Text(call.name).font(.caption.bold()).foregroundColor(.primary)
                }
            }
            if let intent = call.intent {
                Text(intent)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.leading, call.command != nil ? 14 : 0)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    @ViewBuilder
    private func timerLabel(startTime: Date?, duration: TimeInterval?) -> some View {
        if let duration {
            Text(formatDuration(duration))
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.55))
        } else if let startTime {
            TimelineView(.periodic(from: startTime, by: 1)) { context in
                Text(formatDuration(context.date.timeIntervalSince(startTime)))
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.55))
            }
        }
    }
    
    private var fallbackView: some View {
        HStack(alignment: .top) {
            if text.hasPrefix("Running tool:") {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundColor(.blue)
                Text(text)
                    .foregroundColor(.blue)
            } else if text.contains("Hook blocked") || text.contains("denied permission") {
                Image(systemName: "xmark.shield.fill")
                    .foregroundColor(.red)
                Text(text)
                    .foregroundColor(.red)
            } else {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.secondary)
                Text(text)
            }
        }
        .font(.caption.monospaced())
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
        .cornerRadius(12)
        .cornerRadius(0, corners: [.bottomLeft])
    }
}

struct ApprovalBannerView: View {
    let request: ToolApprovalRequest
    let queueDepth: Int
    let onResolve: (AppState.ApprovalResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                Text("Security Guard: Permission Required")
                    .font(.headline)
                Spacer()
                if queueDepth > 1 {
                    Text("\(queueDepth - 1) more pending")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: request.origin.hasPrefix("Subagent") ? "cpu" : "person.fill")
                Text(request.origin)
            }
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.irisIndigo.opacity(0.18)))
            .foregroundColor(.irisIndigo)

            Text("wants to run a potentially sensitive action:")
                .font(.subheadline)

            Text("\(request.toolName): \(request.details)")
                .font(.caption.monospaced())
                .padding(8)
                .background(Color.black.opacity(0.1))
                .cornerRadius(4)
            
            HStack {
                Button(action: { onResolve(.alwaysAllowGlobal) }) {
                    Text("Always Allow (Global)")
                }
                
                if request.workspace != nil {
                    Button(action: { onResolve(.alwaysAllowProject) }) {
                        Text("Always Allow (Project)")
                    }
                }
                
                Spacer()
                
                Button(role: .cancel, action: { onResolve(.deny) }) {
                    Text("Deny")
                }
                .keyboardShortcut(.cancelAction)
                
                Button(action: { onResolve(.approve) }) {
                    Text("Approve Once")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.22), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
        )
        .frame(maxWidth: 560)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// Helper to round specific corners in SwiftUI
struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: RectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = NSBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadius: radius)
        return Path(path.cgPath)
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape( RoundedCorner(radius: radius, corners: corners) )
    }
}

// macOS NSBezierPath extension for rounded corners
extension NSBezierPath {
    convenience init(roundedRect rect: CGRect, byRoundingCorners corners: RectCorner, cornerRadius: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        self.init()
        self.append(NSBezierPath(cgPath: path))
    }
    
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<self.elementCount {
            let type = self.element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

struct TypingIndicator: View {
    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 0.3
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.irisIndigo)
                .frame(width: 6, height: 6)
                .scaleEffect(scale)
                .opacity(opacity)
                .animation(.easeInOut(duration: 0.6).repeatForever().delay(0.0), value: scale)
            Circle()
                .fill(Color.irisBlue)
                .frame(width: 6, height: 6)
                .scaleEffect(scale)
                .opacity(opacity)
                .animation(.easeInOut(duration: 0.6).repeatForever().delay(0.2), value: scale)
            Circle()
                .fill(Color.irisTeal)
                .frame(width: 6, height: 6)
                .scaleEffect(scale)
                .opacity(opacity)
                .animation(.easeInOut(duration: 0.6).repeatForever().delay(0.4), value: scale)
        }
        .onAppear {
            scale = 1.0
            opacity = 1.0
        }
    }
}

struct SlashCommandAutoCompleteView: View {
    var model: SlashCommandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.irisIndigo)
                    .font(.caption)
                Text("SLASH COMMANDS")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { idx, item in
                    Button(action: { model.selectedIndex = idx; model.commitSelected() }) {
                        HStack {
                            Text(item.usage)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                                .foregroundColor(.irisIndigo)

                            Spacer()

                            Text(item.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(idx == model.selectedIndex
                                ? Color.irisIndigo.opacity(0.18)
                                : Color.primary.opacity(0.04))
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(.thinMaterial)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.bottom, 4)
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
    if s < 60   { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}
