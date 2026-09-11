import SwiftUI
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
        case .harnessImport: return "import"
        case .convertLegacy(let name): return "convert:\(name)"
        }
    }
}

/// Serializes a single "the next legacy-file-watcher tick is self-inflicted" flag so the
/// convert-to-plugin flow's own write to mcp_servers.json doesn't trigger a second, redundant
/// fleet-wide `reloadServers()` on top of the targeted restart it already did. MainActor-isolated
/// because it's only ever touched from UI-driven `Task { @MainActor ... }` work.
@MainActor
enum LegacyFileWatchSuppressor {
    private static var suppressedAt: Date?

    /// Call immediately before a self-inflicted write to mcp_servers.json.
    static func suppressNext() { suppressedAt = Date() }

    /// Called by the watcher's handler; returns true (and clears the flag) exactly once per
    /// `suppressNext()` call, so a genuine follow-up hand-edit still triggers a normal reload.
    /// The flag expires after 3 seconds: if the watcher tick for a self-inflicted write never
    /// arrives (FSEvents coalescing, watcher not running), a stale flag must not swallow a
    /// genuine hand-edit minutes later. Either way the flag is cleared.
    static func consumeSuppression() -> Bool {
        defer { suppressedAt = nil }
        guard let suppressedAt else { return false }
        return Date().timeIntervalSince(suppressedAt) < 3
    }
}

struct PluginsSettingsView: View {
    @State private var plugins: [LoadedPlugin] = []
    @State private var serverStatuses: [String: MCPManager.ServerStatus] = [:]
    @State private var selectedID: String?
    @State private var showInstallWizard: InstallWizardSource?
    private let legacyFileWatcher = FileWatcher()

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 230, maxWidth: 300)
            detailPane
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await refresh() }
        // No explicit teardown call is needed here: FileWatcher.watch(paths:)'s AsyncStream sets
        // `continuation.onTermination = { [weak self] _ in self?.stop() }` (FileWatcher.swift:71-73),
        // and the Swift stdlib's AsyncStream.Iterator.next() wraps its await in
        // withTaskCancellationHandler, calling the stream's cancellation path (which fires
        // onTermination) when the enclosing Task is cancelled. `.task` cancels its Task on view
        // disappearance, so this `for await` loop's cancellation deterministically reaches
        // FileWatcher.stop() (FileWatcher.swift:77-84), which stops/invalidates/releases the
        // FSEventStream. Repeated tab visits create a fresh FileWatcher-owned stream per `.task`
        // run and tear down the prior one on each disappearance — no leak.
        .task { await watchLegacyFile() }
        .sheet(item: $showInstallWizard) { source in
            PluginInstallWizardView(source: source) {
                Task { await refresh() }
            }
        }
    }

    private func watchLegacyFile() async {
        let path = IrisPaths.default.mcpServersJSON.path
        for await _ in legacyFileWatcher.watch(paths: [path]) {
            if LegacyFileWatchSuppressor.consumeSuppression() {
                // Self-inflicted write (e.g. convert-to-plugin's removeLegacyServer); the
                // install flow already did a targeted start/stop, so skip the redundant
                // fleet-wide reload but still refresh the UI's view of server statuses.
                await refresh()
                continue
            }
            // Push fresh plugin configs before the fleet restart: reloadServers() restarts
            // from MCPManager's stored plugin configs, and stale state here would resurrect
            // servers (with expanded secrets) of plugins uninstalled since the last push.
            await PluginManager.shared.loadAll()
            await MCPManager.shared.setPluginConfigs(await PluginManager.shared.mcpConfigs())
            await MCPManager.shared.reloadServers()
            await refresh()
        }
    }

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedID) {
                Section("Plugins") {
                    ForEach(plugins, id: \.manifest.id) { plugin in
                        HStack {
                            statusLED(for: plugin)
                            VStack(alignment: .leading) {
                                Text(plugin.manifest.name).fontWeight(.medium)
                                Text(subtitle(for: plugin)).font(.caption).foregroundStyle(.secondary)
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
                            )).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        .tag(plugin.manifest.id)
                    }
                }
                Section("Configured in file") {
                    ForEach(legacyServerNames, id: \.self) { name in
                        HStack {
                            Circle().fill(legacyColor(name)).frame(width: 8, height: 8)
                            Text(name)
                            Spacer()
                        }
                        .contextMenu {
                            Button("Convert to Plugin…") { showInstallWizard = .convertLegacy(name: name) }
                        }
                    }
                    Button("Edit mcp_servers.json") {
                        NSWorkspace.shared.open(IrisPaths.default.mcpServersJSON)
                    }.buttonStyle(.link)
                }
            }
            Menu("＋ Add Plugin") {
                Button("From Folder…") { pickFolder() }
                Button("From MCP Snippet…") { showInstallWizard = .snippet }
                Button("Import from Another Harness…") { showInstallWizard = .harnessImport }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let plugin = plugins.first(where: { $0.manifest.id == selectedID }) {
            PluginDetailView(plugin: plugin, serverStatuses: serverStatuses) {
                Task { await refresh() }
            }
        } else {
            Text("Select a plugin").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusLED(for plugin: LoadedPlugin) -> some View {
        let color: Color
        switch plugin.status {
        case .ok: color = .green
        case .needsConfig: color = .orange
        case .failed: color = .red
        case .disabled: color = .gray
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private func subtitle(for plugin: LoadedPlugin) -> String {
        switch plugin.status {
        case .ok: return plugin.manifest.version
        case .needsConfig(let reason): return reason
        case .failed(let reason): return reason
        case .disabled: return "disabled"
        }
    }

    private var legacyServerNames: [String] {
        serverStatuses.keys.filter { !$0.contains(".") }.sorted()
    }

    private func legacyColor(_ name: String) -> Color {
        if case .running = serverStatuses[name] { return .green }
        return .red
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            showInstallWizard = .folder(url)
        }
    }

    private func refresh() async {
        plugins = await PluginManager.shared.plugins()
        serverStatuses = await MCPManager.shared.serverStatuses()
        if selectedID == nil { selectedID = plugins.first?.manifest.id }
    }

    private func restartMCP(forPlugin id: String) async {
        await PluginsSettingsView.restartMCP(forPlugin: id)
    }
}

/// Restarts only the servers owned by one plugin, leaving everything else running.
/// `startServers()` skips names already present in `servers`, so unrelated servers
/// (legacy or other plugins) are untouched.
extension PluginsSettingsView {
    static func restartMCP(forPlugin id: String) async {
        await MCPManager.shared.stopServers(withPrefix: "\(id).")
        let configs = await PluginManager.shared.mcpConfigs()
        await MCPManager.shared.setPluginConfigs(configs)
        await MCPManager.shared.startServers()
    }
}

struct PluginDetailView: View {
    let plugin: LoadedPlugin
    let serverStatuses: [String: MCPManager.ServerStatus]
    let onChange: () -> Void

    @State private var secretDrafts: [String: String] = [:]
    @State private var configDrafts: [String: String] = [:]
    @State private var authStatuses: [Int: PluginAuthStatus] = [:]
    @State private var confirmingUninstall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if plugin.manifest.config?.isEmpty == false || plugin.manifest.secrets?.isEmpty == false
                    || plugin.manifest.auth?.isEmpty == false {
                    configurationCard
                }
                serversCard
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
        VStack(alignment: .leading, spacing: 2) {
            Text(plugin.manifest.name).font(.title2).bold()
            Text([plugin.manifest.version, plugin.manifest.author, plugin.state.source]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let homepage = plugin.manifest.homepage, let url = URL(string: homepage) {
                Link(homepage, destination: url).font(.caption)
            }
        }
    }

    private var configurationCard: some View {
        GroupBox("Configuration") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plugin.manifest.config ?? [], id: \.key) { field in
                    HStack {
                        Text(field.label ?? field.key).frame(width: 160, alignment: .trailing)
                        TextField(field.help ?? "", text: Binding(
                            get: { configDrafts[field.key] ?? "" },
                            set: { configDrafts[field.key] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveConfig(field.key) }
                    }
                }
                ForEach(plugin.manifest.secrets ?? [], id: \.key) { field in
                    HStack {
                        Text(field.label ?? field.key).frame(width: 160, alignment: .trailing)
                        SecureField("stored in Keychain", text: Binding(
                            get: { secretDrafts[field.key] ?? "" },
                            set: { secretDrafts[field.key] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveSecret(field.key) }
                    }
                }
                ForEach(Array((plugin.manifest.auth ?? []).enumerated()), id: \.offset) { index, auth in
                    HStack {
                        Text(auth.label ?? "Account").frame(width: 160, alignment: .trailing)
                        if authStatuses[index]?.signedIn == true {
                            Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("Sign in required", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        }
                        Button("Sign In") { runSetup(index: index, auth: auth) }
                    }
                }
            }
            .padding(6)
        }
    }

    private var serversCard: some View {
        GroupBox("Servers & Tools") {
            VStack(alignment: .leading, spacing: 6) {
                let prefix = "\(plugin.manifest.id)."
                let mine = serverStatuses.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
                if mine.isEmpty {
                    Text("No servers running").foregroundStyle(.secondary)
                }
                ForEach(mine, id: \.key) { name, status in
                    HStack {
                        switch status {
                        case .running(let count):
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("\(name.dropFirst(prefix.count)) — running · \(count) tools")
                        case .failed(let reason):
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text("\(name.dropFirst(prefix.count)) — \(reason)").foregroundStyle(.secondary)
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
            Button("Uninstall…", role: .destructive) { confirmingUninstall = true }
                .confirmationDialog(
                    "Uninstall \(plugin.manifest.name)? Its Keychain secrets are deleted. Credentials owned by external tools (e.g. nlm) are left alone.",
                    isPresented: $confirmingUninstall) {
                    Button("Uninstall", role: .destructive) {
                        Task {
                            try? await PluginInstaller(paths: .default).uninstall(id: plugin.manifest.id)
                            await PluginManager.shared.loadAll()
                            // Drop the uninstalled plugin's configs from MCPManager so a later
                            // reloadServers() cannot resurrect its servers from stale state.
                            await MCPManager.shared.setPluginConfigs(await PluginManager.shared.mcpConfigs())
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
        for (index, auth) in (plugin.manifest.auth ?? []).enumerated() {
            authStatuses[index] = await PluginAuthRunner.check(auth, config: configDrafts)
        }
    }

    private func saveConfig(_ key: String) {
        Task {
            await PluginManager.shared.setConfigValue(plugin.manifest.id, key: key, value: configDrafts[key] ?? "")
            await PluginsSettingsView.restartMCP(forPlugin: plugin.manifest.id)
            onChange()
        }
    }

    private func saveSecret(_ key: String) {
        let service = KeychainManager.pluginService(plugin.manifest.id)
        var secrets = KeychainManager.shared.secrets(service: service)
        secrets[key] = secretDrafts[key]
        KeychainManager.shared.saveSecrets(secrets, service: service)
        Task {
            await PluginManager.shared.loadAll()
            await PluginsSettingsView.restartMCP(forPlugin: plugin.manifest.id)
            onChange()
        }
    }

    private func runSetup(index: Int, auth: IPFManifest.AuthDeclaration) {
        Task {
            _ = await PluginAuthRunner.runSetup(auth, config: configDrafts)
            authStatuses[index] = await PluginAuthRunner.check(auth, config: configDrafts)
        }
    }
}
