import SwiftUI

/// Settings → Models → Subagent providers (#239): the built-in families' switches and the
/// custom OpenAI-compatible endpoints. Never shows a key's value.
struct SubagentProvidersSection: View {
    @Bindable var config: ConfigManager
    var keychain: KeychainManager = .shared

    /// Bumped after each edit, so rows re-read the defaults-backed lists.
    @State private var revision = 0
    @State private var editing: EndpointDraft?
    @State private var checks: [String: CheckState] = [:]

    enum CheckState: Equatable {
        case running
        case done([(id: String, found: Bool)])
        case failed(String)

        static func == (a: CheckState, b: CheckState) -> Bool {
            switch (a, b) {
            case (.running, .running): true
            case (.failed(let x), .failed(let y)): x == y
            case (.done(let x), .done(let y)): x.map(\.id) == y.map(\.id) && x.map(\.found) == y.map(\.found)
            default: false
            }
        }
    }

    var body: some View {
        let _ = revision
        let registry = config.providerRegistry(keychain: keychain)
        Section(header: Text("Subagent providers").font(.headline)) {
            Text("A subagent can run on one of these instead of the primary provider, for example a security review on another model family. The main conversation always uses the primary.")
                .font(.caption).foregroundColor(.secondary)

            ForEach(LLMProvider.allCases.filter { $0.rawValue != config.primaryProvider }, id: \.self) { family in
                builtInRow(family, registry.first { $0.id == ProviderSlug.id(of: family) })
            }

            ForEach(config.subagentEndpoints) { endpoint in
                endpointRow(endpoint, registry.first { $0.id == endpoint.id })
            }
            if config.undecodableSubagentEndpoints > 0 {
                Text("\(config.undecodableSubagentEndpoints) saved endpoint(s) couldn't be read and are ignored.")
                    .font(.caption).foregroundColor(.orange)
            }

            Menu("Add endpoint…") {
                ForEach(EndpointDraft.Preset.allCases, id: \.self) { preset in
                    Button(preset.title) { editing = EndpointDraft(preset: preset) }
                }
            }
        }
        .sheet(item: $editing) { draft in
            EndpointEditor(draft: draft, taken: Set(config.subagentEndpoints.map(\.id))) { saved, key in
                try config.saveSubagentEndpoint(saved, key: key, replacing: draft.originalId, keychain: keychain)
                revision += 1
            }
        }
    }

    // MARK: Built-in families

    private func builtInRow(_ family: LLMProvider, _ entry: RegisteredProvider?) -> some View {
        let use = config.subagentBuiltIns[family.rawValue] ?? BuiltInSubagentUse()
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { use.enabled }, set: { on in
                config.setSubagentUse(BuiltInSubagentUse(enabled: on, extraModels: use.extraModels), for: family)
                revision += 1
            })) {
                Text("\(family.rawValue): usable by subagents")
            }
            .disabled(entry?.hasKey != true)
            Text(entry?.hasKey == true
                 ? "Its tier models, plus any extra models below. Subagents sent here send their whole context to \(family.rawValue)."
                 : "No key set for \(family.rawValue). Add one under LLM Providers to use it for subagents.")
                .font(.caption).foregroundColor(.secondary)
            if use.enabled {
                TextField("Extra subagent models (comma-separated, exact ids)", text: Binding(
                    get: { use.extraModels.joined(separator: ", ") },
                    set: { text in
                        config.setSubagentUse(BuiltInSubagentUse(enabled: true, extraModels: EndpointDraft.split(text)), for: family)
                        revision += 1
                    }))
            }
        }
    }

    // MARK: Custom endpoints

    private func endpointRow(_ endpoint: ProviderEndpoint, _ entry: RegisteredProvider?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(endpoint.name).font(.body.bold())
                Text(endpoint.id).font(.caption.monospaced()).foregroundColor(.secondary)
                Spacer()
                Button("Check") { check(endpoint) }
                    .disabled(checks[endpoint.id] == .running)
                Button("Edit") { editing = EndpointDraft(endpoint) }
                Button("Remove", role: .destructive) {
                    config.removeSubagentEndpoint(id: endpoint.id, keychain: keychain)
                    checks[endpoint.id] = nil
                    revision += 1
                }
            }
            Text(endpoint.baseURL).font(.caption.monospaced()).foregroundColor(.secondary)
            Text(keyLine(endpoint, entry)).font(.caption)
                .foregroundColor(entry?.usable == true ? .secondary : .orange)
            Text("Models: \(endpoint.models.isEmpty ? "none yet" : endpoint.models.joined(separator: ", "))")
                .font(.caption)
            Text("A subagent sent here sends its whole context, workspace content included, to this endpoint.")
                .font(.caption).foregroundColor(.secondary)
            checkLine(endpoint.id)
        }
    }

    private func keyLine(_ endpoint: ProviderEndpoint, _ entry: RegisteredProvider?) -> String {
        if !endpoint.needsKey { return "No key (a server on this Mac)." }
        if entry?.originChanged == true { return "Key set for a different address: re-enter it with Edit." }
        return entry?.hasKey == true ? "Key set." : "No key set."
    }

    @ViewBuilder private func checkLine(_ id: String) -> some View {
        switch checks[id] {
        case .running?:
            Text("Checking…").font(.caption)
        case .failed(let why)?:
            Text(why).font(.caption).foregroundColor(.orange)
        case .done(let rows)?:
            Text(rows.isEmpty ? "Listed no models." : rows.map { "\($0.id): \($0.found ? "found" : "not found")" }.joined(separator: " · "))
                .font(.caption).foregroundColor(rows.allSatisfy(\.found) ? .green : .orange)
        case nil:
            EmptyView()
        }
    }

    /// Lists the clicked endpoint's models, on demand only, and marks each configured id.
    private func check(_ endpoint: ProviderEndpoint) {
        switch config.checkTarget(for: endpoint.id, keychain: keychain) {
        case .failure(let refusal):
            checks[endpoint.id] = .failed(refusal.message)
        case .success(let target):
            checks[endpoint.id] = .running
            Task {
                let catalog = ModelCatalog(provider: .openai, apiKey: target.apiKey, baseURL: target.baseURL,
                                           session: NoRedirectSessionDelegate.session)
                do {
                    let listed = try await catalog.listModels().map(\.id)
                    checks[endpoint.id] = .done(SubagentModelCheck.compare(configured: endpoint.models, listed: listed))
                } catch {
                    checks[endpoint.id] = .failed(SecretScrub.scrub(error.localizedDescription, [target.apiKey]))
                }
            }
        }
    }
}

/// Which configured ids a provider's model list contains.
enum SubagentModelCheck {
    static func compare(configured: [String], listed: [String]) -> [(id: String, found: Bool)] {
        let set = Set(listed)
        return configured.map { ($0, set.contains($0)) }
    }
}

/// An endpoint being added or edited. The key field starts empty: an edit that leaves it empty
/// keeps the stored key (unless the address changed, which needs it re-entered).
struct EndpointDraft: Identifiable {
    enum Preset: CaseIterable {
        case deepseek, openRouter, ollama, custom
        var title: String {
            switch self {
            case .deepseek: "DeepSeek"
            case .openRouter: "OpenRouter"
            case .ollama: "Ollama on this Mac"
            case .custom: "Custom OpenAI-compatible"
            }
        }
    }

    let id = UUID()
    var originalId: String?
    var slug = ""
    var name = ""
    var baseURL = ""
    var models = ""
    var needsKey = true
    var key = ""

    init(preset: Preset) {
        switch preset {
        case .deepseek: (slug, name, baseURL) = ("deepseek", "DeepSeek", "https://api.deepseek.com/v1")
        case .openRouter: (slug, name, baseURL) = ("openrouter", "OpenRouter", "https://openrouter.ai/api/v1")
        case .ollama: (slug, name, baseURL, needsKey) = ("local-ollama", "Ollama", "http://localhost:11434/v1", false)
        case .custom: break
        }
    }

    init(_ endpoint: ProviderEndpoint) {
        originalId = endpoint.id
        slug = endpoint.id
        name = endpoint.name
        baseURL = endpoint.baseURL
        models = endpoint.models.joined(separator: ", ")
        needsKey = endpoint.needsKey
    }

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var endpoint: ProviderEndpoint {
        ProviderEndpoint(id: slug.trimmingCharacters(in: .whitespaces), name: name, baseURL: baseURL,
                         models: Self.split(models), needsKey: needsKey)
    }
}

private struct EndpointEditor: View {
    @State var draft: EndpointDraft
    let taken: Set<String>
    let save: (ProviderEndpoint, String?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
            TextField("Id (lowercase, for example deepseek)", text: $draft.slug)
            TextField("Base URL", text: $draft.baseURL)
            Toggle("Needs a key", isOn: $draft.needsKey)
            if draft.needsKey {
                SecureField(draft.originalId == nil ? "API key" : "API key (leave empty to keep the stored one)", text: $draft.key)
            }
            TextField("Model ids (comma-separated, exact)", text: $draft.models)
            Text("A subagent sent here sends its whole context, workspace content included, to this endpoint.")
                .font(.caption).foregroundColor(.secondary)
            if let error { Text(error).font(.caption).foregroundColor(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    do {
                        let key: String? = draft.needsKey ? (draft.key.isEmpty ? nil : draft.key) : ""
                        try save(draft.endpoint, key)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
