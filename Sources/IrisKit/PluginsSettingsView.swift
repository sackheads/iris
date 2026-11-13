import SwiftUI
import AppKit
import MarkdownUI

enum InstallWizardSource: Identifiable {
    case folder(URL)
    case snippet
    case harnessImport
    case convertLegacy(name: String)

    var id: String {
        switch self {
        case .folder(let url): return "folder:\(url.path)"
        case .snippet: return "snippet"
        case .harnessImport: return "harness"
        case .convertLegacy(let name): return "convert:\(name)"
        }
    }
}

/// Serializes a single "the next legacy-file-watcher tick is self-inflicted" flag so the
/// convert-to-plugin flow's own `removeLegacyServer` write doesn't trigger a redundant
/// fleet-wide `reloadServers()` on top of the targeted restart it already did. MainActor-isolated
/// so the flag is set before the write and consumed when the FSEvents tick hops back to the view.
@MainActor
enum LegacyFileWatchSuppressor {
    private static var suppressedUntil: ContinuousClock.Instant?

    static func suppressNext() {
        suppressedUntil = ContinuousClock.now + .seconds(3)
    }

    static func consumeSuppression() -> Bool {
        guard let deadline = suppressedUntil else { return false }
        suppressedUntil = nil
        return ContinuousClock.now < deadline
    }
}

enum PluginsSidebarSelection: Hashable {
    case addServer
    case plugin(String)
    case legacy(String)
}

struct PluginsSettingsView: View {
    static let explanation =
        "Connect remote HTTP or local stdio MCP tool servers, or install multi-component plugins (MCP servers, skills, and rules) with secrets stored in the macOS Keychain."
    static let docsURL = URL(string: "https://github.com/sackheads/iris/blob/main/docs/features.md#plugins")!

    @State private var plugins: [LoadedPlugin] = []
    @State private var serverStatuses: [String: MCPManager.ServerStatus] = [:]
    @State private var serverTools: [String: [MCPManager.ToolSummary]] = [:]
    @State private var legacyFile = MCPManager.LegacyFile()
    @State private var selection: PluginsSidebarSelection?
    @State private var showInstallWizard: InstallWizardSource?
    @State private var reloadingAll = false
    private let legacyFileWatcher = FileWatcher()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 250)
            Divider()
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Reserve space for the window titlebar and outer chrome (#992).
        .padding(.top, 28)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .task { await initialLoad() }
        .task { await watchLegacyFile() }
        .sheet(item: $showInstallWizard) { source in
            PluginInstallWizardView(source: source) {
                Task { await refresh() }
            }
        }
    }

    private func initialLoad() async {
        await PluginManager.shared.loadAll()
        let configs = await PluginManager.shared.mcpConfigs()
        await MCPManager.shared.setPluginConfigs(configs)
        await MCPManager.shared.startServers()
        await refresh()
    }

    private func watchLegacyFile() async {
        let path = IrisPaths.default.mcpServersJSON.path
        for await _ in legacyFileWatcher.watch(paths: [path]) {
            if LegacyFileWatchSuppressor.consumeSuppression() {
                await refresh()
                continue
            }
            await reloadAllServers()
        }
    }

    private func reloadAllServers() async {
        reloadingAll = true
        await PluginManager.shared.loadAll()
        await MCPManager.shared.setPluginConfigs(await PluginManager.shared.mcpConfigs())
        await MCPManager.shared.reloadServers()
        await refresh()
        reloadingAll = false
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                selection = .addServer
            } label: {
                Label("Add MCP Server...", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            List(selection: $selection) {
                Section("Configured Servers & Plugins") {
                    if plugins.isEmpty && legacyServerNames.isEmpty {
                        Text("No servers configured yet. Use the form on the right to add one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    }
                    ForEach(plugins, id: \.manifest.id) { plugin in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor(for: plugin))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plugin.manifest.name)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text(subtitle(for: plugin))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { plugin.state.enabled },
                                set: { enabled in
                                    Task {
                                        await PluginManager.shared.setEnabled(plugin.manifest.id, enabled: enabled)
                                        await restartMCP(forPlugin: plugin.manifest.id)
                                        await refresh()
                                    }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                        .tag(PluginsSidebarSelection.plugin(plugin.manifest.id))
                    }

                    ForEach(legacyServerNames, id: \.self) { name in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(legacyColor(name))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(name)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Text("file")
                                        .font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.18))
                                        .clipShape(Capsule())
                                }
                                Text(legacySubtitle(name))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .tag(PluginsSidebarSelection.legacy(name))
                        .contextMenu {
                            Button("Convert to Managed Server...") {
                                Task { await convertLegacyInline(name: name) }
                            }
                            Button("Remove from mcp_servers.json", role: .destructive) {
                                Task { await removeLegacy(name: name) }
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    Task { await reloadAllServers() }
                } label: {
                    Label(reloadingAll ? "Reloading..." : "Reload All", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(reloadingAll)

                Spacer()

                Link("Docs", destination: Self.docsURL)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .plugin(let id):
            if let plugin = plugins.first(where: { $0.manifest.id == id }) {
                PluginDetailView(
                    plugin: plugin,
                    serverStatuses: serverStatuses,
                    serverTools: serverTools,
                    onChange: { Task { await refresh() } },
                    onRemoved: {
                        selection = nil
                        Task { await refresh() }
                    }
                )
            } else {
                addServerWorkspace
            }
        case .legacy(let name):
            if legacyServerNames.contains(name) {
                LegacyServerDetailView(
                    name: name,
                    config: legacyFile.configs[name],
                    status: serverStatuses[name] ?? legacyFile.failures[name].map { .failed($0) },
                    tools: serverTools[name] ?? [],
                    onConvert: { await convertLegacyInline(name: name) },
                    onRemove: { await removeLegacy(name: name) },
                    onRefresh: { await refresh() }
                )
            } else {
                addServerWorkspace
            }
        case .addServer, nil:
            addServerWorkspace
        }
    }

    private var addServerWorkspace: some View {
        AddMCPServerWorkspaceView { installedPluginID in
            await refresh()
            if let installedPluginID {
                selection = .plugin(installedPluginID)
            }
        }
    }

    // MARK: - Status & Subtitle Helpers

    private func statusColor(for plugin: LoadedPlugin) -> Color {
        switch plugin.status {
        case .disabled: return .gray
        case .needsConfig: return .orange
        case .failed: return .red
        case .ok:
            let prefix = "\(plugin.manifest.id)."
            let mine = serverStatuses.filter { $0.key.hasPrefix(prefix) }.map(\.value)
            if mine.contains(where: { if case .failed = $0 { return true }; return false }) {
                return .red
            }
            return .green
        }
    }

    private func subtitle(for plugin: LoadedPlugin) -> String {
        switch plugin.status {
        case .disabled:
            return "Disabled"
        case .needsConfig(let reason):
            return reason
        case .failed(let reason):
            return reason
        case .ok:
            let prefix = "\(plugin.manifest.id)."
            let mine = serverStatuses.filter { $0.key.hasPrefix(prefix) }.map(\.value)
            if let firstFailed = mine.compactMap({ status -> String? in
                if case .failed(let reason) = status { return reason }
                return nil
            }).first {
                return "Failed: \(firstFailed)"
            }
            let toolCounts = mine.compactMap { status -> Int? in
                if case .running(let count) = status { return count }
                return nil
            }
            if !toolCounts.isEmpty {
                let total = toolCounts.reduce(0, +)
                return "Connected · \(total) tool\(total == 1 ? "" : "s")"
            }
            return plugin.manifest.version
        }
    }

    private var legacyServerNames: [String] {
        let statusKeys = serverStatuses.keys.filter { !$0.contains(".") }
        return Set(statusKeys).union(legacyFile.names).union(legacyFile.failures.keys).sorted()
    }

    private func legacyColor(_ name: String) -> Color {
        if case .running = serverStatuses[name] { return .green }
        return .red
    }

    private func legacySubtitle(_ name: String) -> String {
        if let status = serverStatuses[name] {
            switch status {
            case .running(let count):
                return "Connected · \(count) tool\(count == 1 ? "" : "s")"
            case .failed(let reason):
                return reason
            }
        }
        if let failure = legacyFile.failures[name] {
            return failure
        }
        return "Not started"
    }

    private func refresh() async {
        plugins = await PluginManager.shared.plugins()
        serverStatuses = await MCPManager.shared.serverStatuses()
        serverTools = await MCPManager.shared.serverTools()
        legacyFile = await MCPManager.shared.legacyFileSnapshot()

        if let current = selection {
            switch current {
            case .plugin(let id) where !plugins.contains(where: { $0.manifest.id == id }):
                selection = nil
            case .legacy(let name) where !legacyServerNames.contains(name):
                selection = nil
            default:
                break
            }
        }
        if selection == nil {
            if let firstPlugin = plugins.first {
                selection = .plugin(firstPlugin.manifest.id)
            } else if let firstLegacy = legacyServerNames.first {
                selection = .legacy(firstLegacy)
            } else {
                selection = .addServer
            }
        }
    }

    private func restartMCP(forPlugin id: String) async {
        await PluginsSettingsView.restartMCP(forPlugin: id)
    }

    private func convertLegacyInline(name: String) async {
        do {
            let raw = try HarnessConfigImporter.servers(at: IrisPaths.default.mcpServersJSON)
            guard let entry = raw[name] else {
                showInstallWizard = .convertLegacy(name: name)
                return
            }
            let snippet = HarnessConfigImporter.snippetJSON(serverName: name, raw: entry)
            var draft = try PluginInstaller.draft(fromSnippet: snippet)
            draft.source = "convert"
            draft = try PluginInstaller.regenerate(draft)
            try PluginInstaller(paths: .default).commit(draft)

            await PluginManager.shared.loadAll()
            let configs = await PluginManager.shared.mcpConfigs()
            await MCPManager.shared.setPluginConfigs(configs)
            await MCPManager.shared.startServers()

            LegacyFileWatchSuppressor.suppressNext()
            await MCPManager.shared.removeLegacyServer(named: name)
            await MCPManager.shared.stopServer(named: name)
            await refresh()
            selection = .plugin(draft.manifest.id)
        } catch {
            showInstallWizard = .convertLegacy(name: name)
        }
    }

    private func removeLegacy(name: String) async {
        LegacyFileWatchSuppressor.suppressNext()
        await MCPManager.shared.removeLegacyServer(named: name)
        await MCPManager.shared.stopServer(named: name)
        await refresh()
    }
}

/// Restarts only the servers owned by one plugin, leaving everything else running.
extension PluginsSettingsView {
    static func restartMCP(forPlugin id: String) async {
        await MCPManager.shared.stopServers(withPrefix: "\(id).")
        let configs = await PluginManager.shared.mcpConfigs()
        await MCPManager.shared.setPluginConfigs(configs)
        await MCPManager.shared.startServers()
    }
}

// MARK: - Inline "Add MCP Server" Workspace

private struct AddMCPServerWorkspaceView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case remote = "Remote (HTTP)"
        case stdio = "Local (stdio)"
        case snippet = "Paste JSON"
        case importExisting = "Import"

        var id: String { rawValue }
    }

    enum RemoteAuthMode: String, CaseIterable, Identifiable {
        case bearer = "Bearer Token"
        case customHeader = "Custom Header"
        case none = "None"

        var id: String { rawValue }
    }

    struct EnvRow: Identifiable {
        let id = UUID()
        var key: String = ""
        var value: String = ""
        var isSecret: Bool = true
    }

    let onInstalled: (String?) async -> Void

    @State private var mode: Mode = .remote

    // Remote form state
    @State private var remoteName = ""
    @State private var remoteURL = ""
    @State private var remoteAuthMode: RemoteAuthMode = .bearer
    @State private var remoteBearerToken = ""
    @State private var customHeaderName = "X-API-Key"
    @State private var customHeaderValue = ""
    @State private var customHeaderIsSecret = true

    // Stdio form state
    @State private var stdioName = ""
    @State private var stdioCommand = ""
    @State private var stdioArgs = ""
    @State private var stdioEnvRows: [EnvRow] = []

    // Snippet state
    @State private var snippetText = ""
    @State private var parsedDraft: PluginDraft?
    @State private var parsedSecretKeys: Set<String> = []

    // Import state
    @State private var detectedHarnesses: [HarnessConfigImporter.DetectedHarness] = []
    @State private var harnessServersByPath: [URL: [String: [String: Any]]] = [:]

    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add MCP Server or Plugin")
                        .font(.title2)
                        .bold()
                    Text(PluginsSettingsView.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Method", selection: $mode) {
                    ForEach(Mode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: mode) { _, newMode in
                    errorMessage = nil
                    if newMode == .importExisting {
                        loadDetectedHarnesses()
                    }
                }

                if let errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                switch mode {
                case .remote:
                    remoteForm
                case .stdio:
                    stdioForm
                case .snippet:
                    snippetForm
                case .importExisting:
                    importForm
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Remote HTTP Form

    private var remoteForm: some View {
        GroupBox("Remote Streamable HTTP Server") {
            VStack(alignment: .leading, spacing: 12) {
                labeledRow("Server Name") {
                    TextField("e.g. sharpei", text: $remoteName)
                        .textFieldStyle(.roundedBorder)
                }
                labeledRow("Endpoint URL") {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("https://sharpei.scromp.net/mcp", text: $remoteURL)
                            .textFieldStyle(.roundedBorder)
                        Text("Requires https:// (or http:// to localhost / 127.0.0.1).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                labeledRow("Authentication") {
                    Picker("", selection: $remoteAuthMode) {
                        ForEach(RemoteAuthMode.allCases) { auth in
                            Text(auth.rawValue).tag(auth)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                switch remoteAuthMode {
                case .bearer:
                    labeledRow("Bearer Token") {
                        VStack(alignment: .leading, spacing: 2) {
                            SecureField("Paste raw token (stored in macOS Keychain)", text: $remoteBearerToken)
                                .textFieldStyle(.roundedBorder)
                            Text("Iris sends `Authorization: Bearer <token>` and stores the token in Keychain (`iris.plugin.<id>`).")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .customHeader:
                    labeledRow("Header Name") {
                        TextField("e.g. X-API-Key", text: $customHeaderName)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledRow("Header Value") {
                        HStack {
                            if customHeaderIsSecret {
                                SecureField("Stored in macOS Keychain", text: $customHeaderValue)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                TextField("Plain header value", text: $customHeaderValue)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Toggle("Secret (Keychain)", isOn: $customHeaderIsSecret)
                                .toggleStyle(.checkbox)
                                .font(.caption)
                        }
                    }
                case .none:
                    EmptyView()
                }

                HStack {
                    Spacer()
                    Button(isSaving ? "Connecting..." : "Add & Connect") {
                        Task { await submitRemoteForm() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || remoteName.trimmingCharacters(in: .whitespaces).isEmpty || remoteURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(8)
        }
    }

    // MARK: Local Stdio Form

    private var stdioForm: some View {
        GroupBox("Local Command (stdio) Server") {
            VStack(alignment: .leading, spacing: 12) {
                labeledRow("Server Name") {
                    TextField("e.g. sqlite", text: $stdioName)
                        .textFieldStyle(.roundedBorder)
                }
                labeledRow("Command") {
                    TextField("e.g. uvx or npx", text: $stdioCommand)
                        .textFieldStyle(.roundedBorder)
                }
                labeledRow("Arguments") {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("e.g. mcp-server-sqlite --db-path ~/mydb.sqlite", text: $stdioArgs)
                            .textFieldStyle(.roundedBorder)
                        Text("Space-separated arguments passed to the command.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Environment & Secrets")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Button("+ Add Variable") {
                            stdioEnvRows.append(EnvRow())
                        }
                        .controlSize(.small)
                    }
                    if stdioEnvRows.isEmpty {
                        Text("Optional. Secret variables are stored in the macOS Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach($stdioEnvRows) { $row in
                        HStack(spacing: 6) {
                            TextField("ENV_KEY", text: $row.key)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 150)
                            if row.isSecret {
                                SecureField("Value (stored in Keychain)", text: $row.value)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                TextField("Value", text: $row.value)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Toggle("Keychain", isOn: $row.isSecret)
                                .toggleStyle(.checkbox)
                                .font(.caption)
                            Button {
                                stdioEnvRows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button(isSaving ? "Starting..." : "Add & Connect") {
                        Task { await submitStdioForm() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || stdioName.trimmingCharacters(in: .whitespaces).isEmpty || stdioCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(8)
        }
    }

    // MARK: Paste JSON Form

    private var snippetForm: some View {
        GroupBox("Paste MCP Server JSON Snippet") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste an `mcpServers` block or single server object (supports `url` / `serverUrl` / `httpUrl` + `headers`, or `command` + `args` + `env`). Iris automatically lifts tokens into the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LiteralTextEditor(text: $snippetText)
                    .frame(height: 150)
                    .border(Color.gray.opacity(0.3))

                HStack {
                    Button("Preview & Extract Secrets") {
                        parseSnippetPreview()
                    }
                    .disabled(snippetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button(isSaving ? "Installing..." : "Install & Connect") {
                        Task { await submitSnippetForm() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || snippetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let draft = parsedDraft {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Detected Server: **\(draft.manifest.name)** (`\(draft.manifest.id)`)")
                            .font(.subheadline)
                        let keys = (draft.secretValues.keys.map { $0 } + draft.configValues.keys.map { $0 }).sorted()
                        if keys.isEmpty {
                            Text("No credentials or environment variables in snippet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(keys, id: \.self) { key in
                                HStack {
                                    Text(key)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(width: 150, alignment: .trailing)
                                    if parsedSecretKeys.contains(key) {
                                        SecureField("Keychain secret", text: snippetValueBinding(key))
                                            .textFieldStyle(.roundedBorder)
                                    } else {
                                        TextField("Config value", text: snippetValueBinding(key))
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    Picker("", selection: snippetSecretTagBinding(key)) {
                                        Text("Secret → Keychain").tag(true)
                                        Text("Plain Config").tag(false)
                                    }
                                    .frame(width: 150)
                                    .labelsHidden()
                                }
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: Import Form

    private var importForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Import from Another App on This Mac") {
                VStack(alignment: .leading, spacing: 10) {
                    if detectedHarnesses.isEmpty {
                        Text("No existing Claude, Cursor, Windsurf, Antigravity, Gemini CLI, or VS Code MCP configs found.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(detectedHarnesses, id: \.configPath) { harness in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(harness.name).fontWeight(.semibold)
                                    Text(harness.configPath.path)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                let servers = harnessServersByPath[harness.configPath] ?? [:]
                                if servers.isEmpty {
                                    Text("No MCP servers configured in this file.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(servers.keys.sorted(), id: \.self) { serverName in
                                        HStack {
                                            Text(serverName)
                                                .font(.system(.body, design: .monospaced))
                                            if let dict = servers[serverName] {
                                                Text(describeRawEntry(dict))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Button("Import & Connect") {
                                                if let raw = servers[serverName] {
                                                    Task {
                                                        await importRawServer(
                                                            serverName: serverName,
                                                            raw: raw,
                                                            source: "import:\(harness.name)"
                                                        )
                                                    }
                                                }
                                            }
                                            .controlSize(.small)
                                            .disabled(isSaving)
                                        }
                                        .padding(.leading, 8)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("Install Multi-Component Plugin Folder") {
                HStack {
                    Text("Load a local IPF plugin directory containing `plugin.md`, skills, rules, or MCP servers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose Folder...") {
                        pickAndInstallFolder()
                    }
                    .disabled(isSaving)
                }
                .padding(8)
            }
        }
        .task { loadDetectedHarnesses() }
    }

    // MARK: Actions

    private func labeledRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .frame(width: 120, alignment: .trailing)
                .padding(.top, 4)
            content()
        }
    }

    private func submitRemoteForm() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let bearer: String? = (remoteAuthMode == .bearer) ? remoteBearerToken : nil
            let headers: [(name: String, value: String, isSecret: Bool)] =
                (remoteAuthMode == .customHeader && !customHeaderName.trimmingCharacters(in: .whitespaces).isEmpty)
                ? [(customHeaderName, customHeaderValue, customHeaderIsSecret)]
                : []
            let draft = try PluginInstaller.draftForRemoteServer(
                name: remoteName,
                urlString: remoteURL,
                bearerToken: bearer,
                customHeaders: headers,
                source: "form"
            )
            try await commitAndStart(draft)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func submitStdioForm() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let args = stdioArgs
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            let env = stdioEnvRows.map { (key: $0.key, value: $0.value, isSecret: $0.isSecret) }
            let draft = try PluginInstaller.draftForStdioServer(
                name: stdioName,
                command: stdioCommand,
                args: args,
                env: env,
                source: "form"
            )
            try await commitAndStart(draft)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func parseSnippetPreview() {
        errorMessage = nil
        do {
            let draft = try PluginInstaller.draft(fromSnippet: snippetText)
            parsedDraft = draft
            parsedSecretKeys = Set(draft.secretValues.keys)
        } catch {
            parsedDraft = nil
            errorMessage = String(describing: error)
        }
    }

    private func submitSnippetForm() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let baseDraft: PluginDraft
            if let existing = parsedDraft {
                baseDraft = try PluginInstaller.regenerate(existing)
            } else {
                baseDraft = try PluginInstaller.draft(fromSnippet: snippetText)
            }
            try await commitAndStart(baseDraft)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func importRawServer(serverName: String, raw: [String: Any], source: String) async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let json = HarnessConfigImporter.snippetJSON(serverName: serverName, raw: raw)
            var draft = try PluginInstaller.draft(fromSnippet: json)
            draft.source = source
            draft = try PluginInstaller.regenerate(draft)
            try await commitAndStart(draft)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func pickAndInstallFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            errorMessage = nil
            isSaving = true
            defer { isSaving = false }
            do {
                let staged = try PluginInstaller(paths: .default).stage(directory: url, source: "local")
                try await commitAndStart(staged)
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func commitAndStart(_ draft: PluginDraft) async throws {
        try PluginInstaller(paths: .default).commit(draft)
        await PluginManager.shared.loadAll()
        await PluginsSettingsView.restartMCP(forPlugin: draft.manifest.id)
        await onInstalled(draft.manifest.id)
    }

    private func loadDetectedHarnesses() {
        let found = HarnessConfigImporter.detect()
        detectedHarnesses = found
        var map: [URL: [String: [String: Any]]] = [:]
        for h in found {
            map[h.configPath] = (try? HarnessConfigImporter.servers(at: h.configPath)) ?? [:]
        }
        harnessServersByPath = map
    }

    private func describeRawEntry(_ dict: [String: Any]) -> String {
        if let url = (dict["url"] ?? dict["serverUrl"] ?? dict["httpUrl"]) as? String {
            return "HTTP · \(url)"
        }
        if let cmd = dict["command"] as? String {
            let args = (dict["args"] as? [String])?.joined(separator: " ") ?? ""
            return "stdio · \(cmd) \(args)".trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    private func snippetValueBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { parsedDraft?.secretValues[key] ?? parsedDraft?.configValues[key] ?? "" },
            set: { newValue in
                if parsedSecretKeys.contains(key) {
                    parsedDraft?.secretValues[key] = newValue
                } else {
                    parsedDraft?.configValues[key] = newValue
                }
            }
        )
    }

    private func snippetSecretTagBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { parsedSecretKeys.contains(key) },
            set: { isSecret in
                guard var d = parsedDraft else { return }
                let value = d.secretValues[key] ?? d.configValues[key] ?? ""
                if isSecret {
                    parsedSecretKeys.insert(key)
                    d.secretValues[key] = value
                    d.configValues[key] = nil
                } else {
                    parsedSecretKeys.remove(key)
                    d.configValues[key] = value
                    d.secretValues[key] = nil
                }
                parsedDraft = d
            }
        )
    }
}

// MARK: - Managed Plugin / Server Detail View

struct PluginDetailView: View {
    let plugin: LoadedPlugin
    let serverStatuses: [String: MCPManager.ServerStatus]
    let serverTools: [String: [MCPManager.ToolSummary]]
    let onChange: () -> Void
    var onRemoved: (() -> Void)? = nil

    @State private var secretDrafts: [String: String] = [:]
    @State private var configDrafts: [String: String] = [:]
    @State private var authStatuses: [Int: PluginAuthStatus] = [:]
    /// "Always allow this command" checkbox state, keyed by auth-entry index. Off by default on
    /// every open (#338).
    @State private var alwaysAllowChecked: [Int: Bool] = [:]
    @State private var confirmingUninstall = false
    @State private var isReconnecting = false
    @State private var savedConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                statusBanner
                if plugin.manifest.config?.isEmpty == false || plugin.manifest.secrets?.isEmpty == false
                    || plugin.manifest.auth?.isEmpty == false {
                    configurationCard
                }
                serversAndToolsCard
                footer
                if !plugin.manifest.markdownBody.isEmpty {
                    Divider()
                    Markdown(plugin.manifest.markdownBody).textSelection(.enabled)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: plugin.manifest.id) { await loadDrafts() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.manifest.name).font(.title2).bold()
                Text([plugin.manifest.version, plugin.manifest.author, plugin.state.source]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let homepage = plugin.manifest.homepage, let url = URL(string: homepage) {
                    Link(homepage, destination: url).font(.caption)
                }
            }
            Spacer()
            Button {
                Task { await reconnectPluginServers() }
            } label: {
                Label(isReconnecting ? "Reconnecting..." : "Reconnect", systemImage: "arrow.clockwise")
            }
            .disabled(isReconnecting || !plugin.state.enabled)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch plugin.status {
        case .needsConfig(let reason):
            bannerView(color: .orange, icon: "key.fill", text: reason)
        case .failed(let reason):
            bannerView(color: .red, icon: "exclamationmark.octagon.fill", text: reason)
        case .disabled:
            bannerView(color: .secondary, icon: "pause.circle", text: "This server is disabled.")
        case .ok:
            let prefix = "\(plugin.manifest.id)."
            let failedReasons = serverStatuses
                .filter { $0.key.hasPrefix(prefix) }
                .compactMap { name, status -> String? in
                    if case .failed(let reason) = status {
                        return "\(name.dropFirst(prefix.count)): \(reason)"
                    }
                    return nil
                }
            if !failedReasons.isEmpty {
                bannerView(color: .red, icon: "exclamationmark.triangle.fill",
                           text: failedReasons.joined(separator: "\n"))
            }
        }
    }

    private func bannerView(color: Color, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var configurationCard: some View {
        GroupBox("Credentials & Configuration") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plugin.manifest.config ?? [], id: \.key) { field in
                    HStack {
                        Text(field.label ?? field.key).frame(width: 160, alignment: .trailing)
                        TextField(field.help ?? "", text: Binding(
                            get: { configDrafts[field.key] ?? "" },
                            set: { configDrafts[field.key] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveAllCredentialsAndReconnect() }
                    }
                }
                ForEach(plugin.manifest.secrets ?? [], id: \.key) { field in
                    HStack {
                        Text(field.label ?? field.key).frame(width: 160, alignment: .trailing)
                        SecureField("Stored in macOS Keychain", text: Binding(
                            get: { secretDrafts[field.key] ?? "" },
                            set: { secretDrafts[field.key] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveAllCredentialsAndReconnect() }
                    }
                }
                if (plugin.manifest.config?.isEmpty == false) || (plugin.manifest.secrets?.isEmpty == false) {
                    HStack {
                        Text("Secrets are stored in Keychain service `iris.plugin.\(plugin.manifest.id)`.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if savedConfirmation {
                            Label("Saved & reconnected", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Button("Save & Reconnect") {
                            saveAllCredentialsAndReconnect()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isReconnecting)
                    }
                }
                ForEach(Array((plugin.manifest.auth ?? []).enumerated()), id: \.offset) { index, auth in
                    authRow(index: index, auth: auth)
                }
            }
            .padding(6)
        }
    }

    /// One `auth` entry. Both commands are shown in full beside the buttons that run them, because
    /// the click is the consent (#336): nothing here asks through the chat window's approval queue.
    private func authRow(index: Int, auth: IPFManifest.AuthDeclaration) -> some View {
        let commands = PluginAuthRunner.displayCommands(auth, config: configDrafts)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(auth.label ?? "Account").frame(width: 160, alignment: .trailing)
                switch authStatuses[index]?.signedIn {
                case true?:
                    Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case false?:
                    Label("Sign in required", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                case nil:
                    Label("Not checked", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
                Button("Check") { runCheck(index: index, auth: auth) }
                    .disabled(!Self.runnable(commands.check))
                Toggle("Always allow this command", isOn: Binding(
                    get: { alwaysAllowChecked[index] ?? false },
                    set: { alwaysAllowChecked[index] = $0 }
                ))
                .toggleStyle(.checkbox)
                .disabled(!Self.runnable(commands.check))
                .help("When checked, clicking Check also writes a permanent \"Always allow\" rule "
                    + "for this exact command, so the next time this pane opens it checks itself. "
                    + "Also lets Iris run this exact command without asking, anywhere.")
                Button("Sign In") { runSetup(index: index, auth: auth) }
                    .disabled(!Self.runnable(commands.setup))
            }
            ForEach([("Check runs", commands.check), ("Sign In runs", commands.setup)], id: \.0) { label, command in
                if let command {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(label):").font(.caption).foregroundStyle(.secondary)
                        Text(command)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if command.containsHiddenCharacters {
                            Text("This command contains line breaks or invisible characters, so it cannot be run from here.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.leading, 168)
                }
            }
        }
    }

    private static func runnable(_ command: String?) -> Bool {
        guard let command else { return false }
        return !command.containsHiddenCharacters
    }

    private var serversAndToolsCard: some View {
        GroupBox("Servers & Discovered Tools") {
            VStack(alignment: .leading, spacing: 10) {
                let prefix = "\(plugin.manifest.id)."
                let mine = serverStatuses.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
                if mine.isEmpty {
                    Text("No active MCP servers for this entry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(mine, id: \.key) { fullName, status in
                    let shortName = String(fullName.dropFirst(prefix.count))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            switch status {
                            case .running(let count):
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                                Text("\(shortName) — Connected · \(count) tool\(count == 1 ? "" : "s")")
                                    .fontWeight(.medium)
                            case .failed(let reason):
                                Circle().fill(Color.red).frame(width: 8, height: 8)
                                Text("\(shortName) — Failed: \(reason)")
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                        if let tools = serverTools[fullName], !tools.isEmpty {
                            MCPToolsListView(tools: tools)
                                .padding(.leading, 14)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private var footer: some View {
        HStack {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([plugin.directory])
            }
            Spacer()
            Button("Remove...", role: .destructive) { confirmingUninstall = true }
                .confirmationDialog(
                    "Remove \(plugin.manifest.name)? Its Keychain secrets (`iris.plugin.\(plugin.manifest.id)`) are deleted too.",
                    isPresented: $confirmingUninstall) {
                    Button("Remove", role: .destructive) {
                        Task {
                            try? await PluginInstaller(paths: .default).uninstall(id: plugin.manifest.id)
                            await PluginManager.shared.loadAll()
                            await MCPManager.shared.setPluginConfigs(await PluginManager.shared.mcpConfigs())
                            onRemoved?()
                            onChange()
                        }
                    }
                }
        }
    }

    private func loadDrafts() async {
        configDrafts = plugin.state.configValues
        let secrets = KeychainManager.shared.secrets(service: KeychainManager.pluginService(plugin.manifest.id))
        secretDrafts = secrets
        alwaysAllowChecked = [:]
        savedConfirmation = false
        let permissions = AppState.shared.permissions
        for (index, auth) in (plugin.manifest.auth ?? []).enumerated() {
            authStatuses[index] = await PluginAuthRunner.statusOnOpen(auth, config: configDrafts,
                                                                      permissions: permissions)
        }
    }

    private func saveAllCredentialsAndReconnect() {
        Task {
            isReconnecting = true
            for field in plugin.manifest.config ?? [] {
                await PluginManager.shared.setConfigValue(
                    plugin.manifest.id, key: field.key, value: configDrafts[field.key] ?? ""
                )
            }
            let service = KeychainManager.pluginService(plugin.manifest.id)
            let currentSecrets = secretDrafts
            KeychainManager.shared.updateSecrets(service: service) { stored in
                for (key, value) in currentSecrets {
                    stored[key] = value.isEmpty ? nil : value
                }
            }
            await PluginManager.shared.loadAll()
            await PluginsSettingsView.restartMCP(forPlugin: plugin.manifest.id)
            isReconnecting = false
            savedConfirmation = true
            onChange()
        }
    }

    private func reconnectPluginServers() async {
        isReconnecting = true
        await PluginManager.shared.loadAll()
        await PluginsSettingsView.restartMCP(forPlugin: plugin.manifest.id)
        isReconnecting = false
        onChange()
    }

    private func runCheck(index: Int, auth: IPFManifest.AuthDeclaration) {
        let command = PluginAuthRunner.displayCommands(auth, config: configDrafts).check
        PluginAuthRunner.applyAlwaysAllow(command: command, requested: alwaysAllowChecked[index] ?? false,
                                          permissions: AppState.shared.permissions)
        Task {
            authStatuses[index] = await PluginAuthRunner.check(auth, config: configDrafts,
                                                               approve: PluginAuthRunner.userClicked)
        }
    }

    private func runSetup(index: Int, auth: IPFManifest.AuthDeclaration) {
        Task {
            _ = await PluginAuthRunner.runSetup(auth, config: configDrafts, approve: PluginAuthRunner.userClicked)
            authStatuses[index] = await PluginAuthRunner.check(auth, config: configDrafts,
                                                               approve: PluginAuthRunner.userClicked)
        }
    }
}

// MARK: - Legacy `mcp_servers.json` Detail View

private struct LegacyServerDetailView: View {
    let name: String
    let config: MCPServerConfig?
    let status: MCPManager.ServerStatus?
    let tools: [MCPManager.ToolSummary]
    let onConvert: () async -> Void
    let onRemove: () async -> Void
    let onRefresh: () async -> Void

    @State private var secretDrafts: [String: String] = [:]
    @State private var isWorking = false
    @State private var savedConfirmation = false

    private var referencedKeys: [String] {
        guard let config else { return [] }
        switch config {
        case .stdio(_, _, let env):
            let keys = (env?.values).map { vals in
                vals.reduce(into: Set<String>()) { $0.formUnion(PluginReferences.keychainKeys(in: $1)) }
            } ?? []
            return keys.sorted()
        case .remote(_, let headers, let allowedKeys):
            var keys = allowedKeys
            for v in headers.values {
                keys.formUnion(PluginReferences.keychainKeys(in: v))
            }
            return keys.sorted()
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(name).font(.title2).bold()
                            Text("mcp_servers.json")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        if let config {
                            Text(describe(config))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button {
                        Task {
                            isWorking = true
                            await MCPManager.shared.restartServer(named: name)
                            await onRefresh()
                            isWorking = false
                        }
                    } label: {
                        Label(isWorking ? "Reconnecting..." : "Reconnect", systemImage: "arrow.clockwise")
                    }
                    .disabled(isWorking)
                }

                if case .failed(let reason) = status {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if name != MCPManager.legacyFileStatusName {
                    GroupBox("Upgrade to Managed Server") {
                        HStack {
                            Text("Convert this `mcp_servers.json` entry into a managed server so its secrets live in an isolated Keychain item (`iris.plugin.\(name)`) and it can be enabled or disabled from the sidebar.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Convert to Managed Server") {
                                Task {
                                    isWorking = true
                                    await onConvert()
                                    isWorking = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isWorking)
                        }
                        .padding(6)
                    }
                }

                if !referencedKeys.isEmpty {
                    GroupBox("Keychain Secrets (`iris.mcp`)") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(referencedKeys, id: \.self) { key in
                                HStack {
                                    Text(key)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(width: 160, alignment: .trailing)
                                    SecureField("Stored in Keychain (iris.mcp)", text: Binding(
                                        get: { secretDrafts[key] ?? "" },
                                        set: { secretDrafts[key] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { saveLegacySecrets() }
                                }
                            }
                            HStack {
                               Spacer()
                               if savedConfirmation {
                                   Label("Saved & reconnected", systemImage: "checkmark.circle.fill")
                                       .font(.caption)
                                       .foregroundStyle(.green)
                               }
                               Button("Save to Keychain & Reconnect") {
                                   saveLegacySecrets()
                               }
                               .buttonStyle(.borderedProminent)
                               .controlSize(.small)
                               .disabled(isWorking)
                            }
                        }
                        .padding(6)
                    }
                }

                GroupBox("Discovered Tools") {
                    VStack(alignment: .leading, spacing: 6) {
                        if tools.isEmpty {
                            Text("No tools registered (server is not connected or returned 0 tools).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            MCPToolsListView(tools: tools)
                        }
                    }
                    .padding(6)
                }

                HStack {
                    Button("Reveal mcp_servers.json in Finder") {
                        let url = IrisPaths.default.mcpServersJSON
                        _ = LegacyServersFile.ensureExists(at: url)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Spacer()
                    if name != MCPManager.legacyFileStatusName {
                        Button("Remove from File", role: .destructive) {
                            Task { await onRemove() }
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: name) {
            secretDrafts = KeychainManager.shared.secrets(service: KeychainManager.mcpFileService)
            savedConfirmation = false
        }
    }

    private func describe(_ config: MCPServerConfig) -> String {
        switch config {
        case .stdio(let command, let args, _):
            return ([command] + args).joined(separator: " ")
        case .remote(let url, _, _):
            return url.absoluteString
        }
    }

    private func saveLegacySecrets() {
        Task {
            isWorking = true
            let drafts = secretDrafts
            KeychainManager.shared.updateSecrets(service: KeychainManager.mcpFileService) { stored in
                for (k, v) in drafts {
                    stored[k] = v.isEmpty ? nil : v
                }
            }
            await MCPManager.shared.restartServer(named: name)
            await onRefresh()
            isWorking = false
            savedConfirmation = true
        }
    }
}

// MARK: - Tools Inspector List

private struct MCPToolsListView: View {
    let tools: [MCPManager.ToolSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tools) { tool in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tool.name)
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.semibold)
                        Text(tool.isReadOnly ? "Read-only" : "Outbound-gated")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(tool.isReadOnly ? Color.green : Color.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((tool.isReadOnly ? Color.green : Color.orange).opacity(0.14))
                            .clipShape(Capsule())
                        if !tool.parameterNames.isEmpty {
                            Text("(\(tool.parameterNames.joined(separator: ", ")))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !tool.description.isEmpty {
                        Text(tool.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

/// The legacy `mcp_servers.json`: a `{ "name": { ... } }` map of stdio or remote entries,
/// optionally `mcpServers`-wrapped (see `MCPManager.parseLegacyFile`). Absent on a home that
/// never had a hand-written server.
enum LegacyServersFile {
    /// Creates an empty `{}` map (and its directory) when the file is missing. Returns whether
    /// the file exists afterwards. An existing file is never touched.
    @discardableResult
    static func ensureExists(at url: URL, fileManager fm: FileManager = .default,
                             beforeCreating: () -> Void = {}) -> Bool {
        if fm.fileExists(atPath: url.path) { return true }
        beforeCreating()
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: url, options: .withoutOverwriting)
            return true
        } catch {
            return fm.fileExists(atPath: url.path)
        }
    }
}
