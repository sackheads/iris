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
    @State private var showSubagents = false
    @State private var showSetupWizard = false
    @Bindable var config = ConfigManager.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    /// Toggled to true when the composer should grab keyboard focus (e.g. after
    /// creating a new conversation). ComposerTextView reads this in updateNSView
    /// and resets it after making itself first responder.
    @State private var composerShouldFocus = false
    
    var body: some View {
        NavigationSplitView {
            VStack {
                List(selection: $state.selectedConversationId) {
                    Section(header: Text("Conversations").font(.caption.weight(.bold)).foregroundColor(.secondary).padding(.bottom, 4)) {
                        ForEach(state.conversations.filter { !$0.isSubagent }) { conv in
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
                                Divider()
                                Button(role: .destructive, action: {
                                    state.deleteConversation(conv.id)
                                }) {
                                    Text("Delete Conversation")
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                
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
                                        MessageView(message: message)
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
                            
                            var text = ""
                            let asMarkdown = ConfigManager.shared.copyChatsAsMarkdown
                            for msg in selectedMessages {
                                let roleName = msg.role == .user ? "You" : (msg.role == .system ? "System" : "Iris")
                                if asMarkdown {
                                    text += "### \(roleName)\n"
                                    if msg.role == .system {
                                        text += "`\(msg.content)`\n\n"
                                    } else {
                                        text += "\(msg.content)\n\n"
                                    }
                                } else {
                                    text += "\(roleName):\n\(msg.content)\n\n"
                                }
                            }
                            return [NSItemProvider(object: text as NSString)]
                        }
                        .background(Color(NSColor.textBackgroundColor))
                        // Single Escape handler: clear a message selection if there is one,
                        // otherwise fall through to interrupting the agent (a no-op when idle).
                        // This replaced the Stop button's own .cancelAction shortcut so Escape
                        // isn't double-handled.
                        .onExitCommand { handleEscape() }
                        .onChange(of: conv.messages.count) { _, _ in
                            DispatchQueue.main.async {
                                selectedMessageIDs.removeAll()
                                proxy.scrollTo("bottomAnchor", anchor: .bottom)
                            }
                        }
                        .onChange(of: conv.messages.last?.content) { _, _ in
                            DispatchQueue.main.async {
                                proxy.scrollTo("bottomAnchor", anchor: .bottom)
                            }
                        }
                        .onChange(of: state.isThinking) { _, isThinking in
                            if isThinking {
                                DispatchQueue.main.async {
                                    proxy.scrollTo("thinkingIndicator", anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: state.activeConversationIndex) { _, _ in
                            DispatchQueue.main.async {
                                selectedMessageIDs.removeAll()
                                proxy.scrollTo("bottomAnchor", anchor: .bottom)
                            }
                        }
                        .onAppear {
                            DispatchQueue.main.async {
                                selectedMessageIDs.removeAll()
                                proxy.scrollTo("bottomAnchor", anchor: .bottom)
                            }
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
                        LockedContractChip(state: state, conversation: conv)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Top-level pause panel (resume controls). Gated here in ChatView — the same
                    // pattern as CompletionReportChip below, which re-renders reliably on state change.
                    if conv.goalContract?.checkpointStatus == .pausedForReview {
                        CheckpointPauseChip(state: state, conversation: conv)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // While paused at a checkpoint, the LockedContractChip's pause section already
                    // shows the self-report + verdict, so suppress the standalone chip to avoid a
                    // duplicate. It reappears for a terminal goal_complete (checkpointStatus != paused).
                    if (conv.lastGoalCompletionReport != nil || conv.lastGoalEvaluation != nil),
                       conv.goalContract?.checkpointStatus != .pausedForReview {
                        CompletionReportChip(
                            state: state,
                            conversationId: conv.id,
                            report: conv.lastGoalCompletionReport,
                            evaluation: conv.lastGoalEvaluation
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    SpectrumLine(active: state.isThinking)

                    ModelLEDBar(isThinking: state.isThinking)

                    messageInputBar
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
                    showSubagents.toggle()
                }) {
                    ZStack {
                        Image(systemName: "cpu")
                        if state.activeSubagents.count > 0 {
                            Text("\(state.activeSubagents.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(3)
                                .background(Color.red)
                                .clipShape(Circle())
                                .offset(x: 8, y: -8)
                        }
                    }
                }
                .popover(isPresented: $showSubagents) {
                    SubagentPopoverView(appState: state)
                }
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
    
    private func exportConversation(id: UUID) {
        guard let conv = state.conversations.first(where: { $0.id == id }) else { return }
        
        var markdown = "# \(conv.title)\n\n"
        for msg in conv.messages {
            let roleName = msg.role == .user ? "You" : (msg.role == .system ? "System" : "Iris")
            markdown += "### \(roleName)\n"
            if msg.role == .system {
                let line = LLMErrorMessage.parse(msg.content)?.headline ?? msg.content
                markdown += "`\(line)`\n\n"
            } else {
                markdown += "\(msg.content)\n\n"
            }
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
        
        var text = ""
        for msg in selectedMessages {
            let roleName = msg.role == .user ? "You" : (msg.role == .system ? "System" : "Iris")
            if asMarkdown {
                text += "### \(roleName)\n"
                if msg.role == .system {
                    text += "`\(msg.content)`\n\n"
                } else {
                    text += "\(msg.content)\n\n"
                }
            } else {
                text += "\(roleName):\n\(msg.content)\n\n"
            }
        }
        
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
                } else if message.role != .command {
                    // .command output is deliberately unlabeled (not attributed to Iris).
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
    
    private var backgroundColor: Color {
        switch message.role {
        case .user: return Color.accentColor
        case .agent, .command: return Color(NSColor.controlBackgroundColor)
        case .system: return Color(NSColor.windowBackgroundColor).opacity(0.8)
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user: return .white
        case .agent, .system, .command: return .primary
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
    /// If the last message is a non-tool system line, show that line instead.
    private var collapsedStatus: String? {
        guard let last = messages.last else { return nil }
        if let call = ToolCallParser.parse(last.content) {
            return call.intent ?? call.command ?? call.name
        }
        if let error = LLMErrorMessage.parse(last.content) {
            return error.headline
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
