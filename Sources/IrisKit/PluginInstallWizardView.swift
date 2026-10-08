import SwiftUI

/// Install wizard sheet. Builds a PluginDraft from the chosen source, walks the user through
/// binary checks and configuration, and only writes anything on the final Install click
/// (PluginInstaller.commit). Cancel at any step leaves no trace.
struct PluginInstallWizardView: View {
    let source: InstallWizardSource
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var draft: PluginDraft?
    @State private var loadError: String?
    @State private var snippetText = ""
    @State private var detectedHarnesses: [HarnessConfigImporter.DetectedHarness] = []
    @State private var selectedHarness: HarnessConfigImporter.DetectedHarness?
    @State private var harnessServers: [String: [String: Any]] = [:]
    @State private var selectedServer: String?
    @State private var secretKeys: Set<String> = []      // wizard-adjustable classification
    @State private var installing = false

    private let steps = ["Source", "Binaries", "Configuration", "Confirm"]

    var body: some View {
        HStack(spacing: 0) {
            stepRail
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                content
                Spacer()
                buttons
            }
            .padding(20)
            .frame(width: 460, alignment: .topLeading)
        }
        .frame(height: 400)
        .task { await prepare() }
    }

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft?.manifest.name ?? "Install Plugin").font(.title3).bold()
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(index < step ? Color.green : (index == step ? Color.accentColor : Color.gray.opacity(0.4)))
                            .frame(width: 20, height: 20)
                        if index < step {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    Text(title).fontWeight(index == step ? .bold : .regular)
                }
            }
            Spacer()
        }
        .padding(18)
        .frame(width: 180, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: sourceStep
        case 1: binariesStep
        case 2: configurationStep
        default: confirmStep
        }
    }

    @ViewBuilder
    private var sourceStep: some View {
        if let loadError {
            Label(loadError, systemImage: "xmark.octagon").foregroundStyle(.red)
        } else {
            switch source {
            case .folder:
                if let draft {
                    Text("Validated **\(draft.manifest.name)** \(draft.manifest.version) — \(draft.files.count) files.")
                } else {
                    ProgressView("Validating…")
                }
            case .snippet:
                Text("Paste a standard `mcpServers` JSON snippet:")
                TextEditor(text: $snippetText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 180)
                    .border(Color.gray.opacity(0.3))
                Button("Parse Snippet") { parseSnippet() }
                    .disabled(snippetText.isEmpty)
            case .harnessImport:
                if detectedHarnesses.isEmpty {
                    Text("No known harness configs found on this Mac.")
                } else {
                    Picker("Harness", selection: $selectedHarness) {
                        Text("Choose…").tag(nil as HarnessConfigImporter.DetectedHarness?)
                        ForEach(detectedHarnesses, id: \.configPath) { harness in
                            Text(harness.name).tag(harness as HarnessConfigImporter.DetectedHarness?)
                        }
                    }
                    .onChange(of: selectedHarness) { _, harness in loadHarnessServers(harness) }
                    Picker("Server", selection: $selectedServer) {
                        Text("Choose…").tag(nil as String?)
                        ForEach(harnessServers.keys.sorted(), id: \.self) { Text($0).tag($0 as String?) }
                    }
                    .onChange(of: selectedServer) { _, server in importServer(server) }
                    Text("Iris reads this config; it never edits it.").font(.caption).foregroundStyle(.secondary)
                }
            case .convertLegacy(let name):
                if let draft {
                    Text("Converting **\(name)** from mcp_servers.json to **\(draft.manifest.name)**.")
                } else {
                    ProgressView("Reading \(name)…")
                }
            }
        }
    }

    @ViewBuilder
    private var binariesStep: some View {
        if let draft {
            ForEach(draft.manifest.requires?.binaries ?? [], id: \.name) { binary in
                if let path = BinaryResolver.resolve(command: binary.name) {
                    Label("\(binary.name) — \(path)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(binary.name) not found", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        if let hint = binary.installHint {
                            HStack {
                                Text(hint).font(.system(.caption, design: .monospaced))
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(hint, forType: .string)
                                }.controlSize(.small)
                            }
                        }
                    }
                }
            }
            if (draft.manifest.requires?.binaries ?? []).isEmpty {
                Text("No binary requirements declared.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var configurationStep: some View {
        if draft != nil {
            Text("Secrets go to the Keychain; config stays plain. Re-tag anything the classifier got wrong.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(allEnvKeys, id: \.self) { key in
                HStack {
                    Text(key).font(.system(.caption, design: .monospaced)).frame(width: 150, alignment: .trailing)
                    if secretKeys.contains(key) {
                        SecureField("", text: valueBinding(key)).textFieldStyle(.roundedBorder)
                    } else {
                        TextField("", text: valueBinding(key)).textFieldStyle(.roundedBorder)
                    }
                    Picker("", selection: tagBinding(key)) {
                        Text("Secret → Keychain").tag(true)
                        Text("Config").tag(false)
                    }.frame(width: 160).labelsHidden()
                }
            }
            if let auths = draft?.manifest.auth, !auths.isEmpty {
                // Consent surface only: the commands are shown, never executed by the wizard.
                // Sign-in happens from the plugin's detail pane after install.
                ForEach(Array(auths.enumerated()), id: \.offset) { _, auth in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(auth.label ?? "Account").fontWeight(.medium)
                        if let setup = auth.setupCommand {
                            Text(setup).font(.system(.caption, design: .monospaced))
                        }
                        if let check = auth.checkCommand {
                            Text(check).font(.system(.caption, design: .monospaced))
                        }
                        Text("Runs when you sign in / check status")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if allEnvKeys.isEmpty && (draft?.manifest.auth ?? []).isEmpty {
                Text("Nothing to configure.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var confirmStep: some View {
        if let loadError {
            Label(loadError, systemImage: "xmark.octagon").foregroundStyle(.red)
        } else if let draft {
            Text("Install **\(draft.manifest.name)** \(draft.manifest.version)?")
            Text("→ \(IrisPaths.default.pluginsDir.appendingPathComponent(draft.manifest.id).path)")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Text("\(secretKeys.count) secret(s) to Keychain · \(draft.configValues.count) config value(s) · nothing written until Install.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .disabled(installing)
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }
                    .disabled(installing)
            }
            if step < steps.count - 1 {
                Button("Next") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == nil)
            } else {
                Button(installing ? "Installing…" : "Install") { install() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == nil || installing)
            }
        }
    }

    // MARK: - Data plumbing

    private var allEnvKeys: [String] {
        guard let draft else { return [] }
        return (draft.secretValues.keys.map { $0 } + draft.configValues.keys.map { $0 }).sorted()
    }

    private func valueBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { draft?.secretValues[key] ?? draft?.configValues[key] ?? "" },
            set: { newValue in
                if secretKeys.contains(key) { draft?.secretValues[key] = newValue }
                else { draft?.configValues[key] = newValue }
            })
    }

    private func tagBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { secretKeys.contains(key) },
            set: { isSecret in
                guard var d = draft else { return }
                let value = d.secretValues[key] ?? d.configValues[key] ?? ""
                if isSecret {
                    secretKeys.insert(key)
                    d.secretValues[key] = value
                    d.configValues[key] = nil
                } else {
                    secretKeys.remove(key)
                    d.configValues[key] = value
                    d.secretValues[key] = nil
                }
                draft = d
            })
    }

    private func prepare() async {
        switch source {
        case .folder(let url):
            do {
                var staged = try PluginInstaller(paths: .default).stage(directory: url, source: "local")
                // Seed declared config (default or empty) and secrets (empty) so the
                // Configuration step actually collects them. Empty secret values are
                // skipped at commit — no empty Keychain entries.
                for field in staged.manifest.config ?? [] where staged.configValues[field.key] == nil {
                    staged.configValues[field.key] = field.default ?? ""
                }
                for field in staged.manifest.secrets ?? [] where staged.secretValues[field.key] == nil {
                    staged.secretValues[field.key] = ""
                }
                draft = staged
                secretKeys = Set(staged.secretValues.keys)
            } catch {
                loadError = String(describing: error)
            }
        case .snippet:
            break
        case .harnessImport:
            detectedHarnesses = HarnessConfigImporter.detect()
        case .convertLegacy(let name):
            do {
                let raw = try HarnessConfigImporter.servers(at: IrisPaths.default.mcpServersJSON)
                if let entry = raw[name] {
                    parseSnippetJSON(HarnessConfigImporter.snippetJSON(serverName: name, raw: entry), source: "convert")
                } else {
                    loadError = "\(name) not found in mcp_servers.json"
                }
            } catch {
                loadError = String(describing: error)
            }
        }
    }

    private func parseSnippet() {
        do {
            let parsed = try PluginInstaller.draft(fromSnippet: snippetText)
            draft = parsed
            secretKeys = Set(parsed.secretValues.keys)
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    private func loadHarnessServers(_ harness: HarnessConfigImporter.DetectedHarness?) {
        guard let harness else { return }
        harnessServers = (try? HarnessConfigImporter.servers(at: harness.configPath)) ?? [:]
    }

    private func importServer(_ server: String?) {
        guard let server, let raw = harnessServers[server] else { return }
        parseSnippetJSON(HarnessConfigImporter.snippetJSON(serverName: server, raw: raw),
                         source: "import:\(selectedHarness?.name ?? "harness")")
    }

    private func parseSnippetJSON(_ json: String, source: String) {
        do {
            var parsed = try PluginInstaller.draft(fromSnippet: json)
            parsed.source = source
            draft = parsed
            secretKeys = Set(parsed.secretValues.keys)
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    private func install() {
        guard var draft else { return }
        loadError = nil
        installing = true
        Task {
            do {
                // Generated (non-folder) drafts: rebuild plugin.md/mcp.json from the final
                // secret/config classification, so re-tagging in the Configuration step is
                // reflected in the committed files.
                if case .folder = source {} else {
                    draft = try PluginInstaller.regenerate(draft)
                }
                try PluginInstaller(paths: .default).commit(draft)
                await PluginManager.shared.loadAll()
                let configs = await PluginManager.shared.mcpConfigs()
                await MCPManager.shared.setPluginConfigs(configs)
                await MCPManager.shared.startServers()
                if case .convertLegacy(let name) = source {
                    // The new namespaced server is already running (startServers() above); tear
                    // down only the old legacy-named one instead of restarting the whole fleet.
                    // Suppress the legacy-file watcher's own reaction to this write, since it
                    // would otherwise redundantly reload every server ~1s later.
                    LegacyFileWatchSuppressor.suppressNext()
                    await MCPManager.shared.removeLegacyServer(named: name)
                    await MCPManager.shared.stopServer(named: name)
                }
                onComplete()
                dismiss()
            } catch {
                loadError = String(describing: error)
                installing = false
            }
        }
    }
}
