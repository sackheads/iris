import Foundation

// Providers a subagent may run on besides the primary (#239, docs/specs/2026-10-19-multi-model-subagents.md).
// The main conversation's provider and tiers never read any of this.

/// A custom OpenAI-compatible endpoint, set only in Settings. Its key lives in the secrets dict
/// under `ProviderSlug.secretName(id)`, never here.
struct ProviderEndpoint: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// A validated slug (`ProviderSlug`): the name the model passes and the key's dict entry.
    var id: String
    var name: String
    var baseURL: String
    /// Exact model ids. A subagent may only name one of these (the bare-alias 404, Fork D).
    var models: [String]
    /// False for a local server that takes no key (Ollama, LM Studio).
    var needsKey: Bool
    /// The LiteLLM family its prices come from (#239 3b), set by its preset. nil falls back to its
    /// host's family (`PriceFamily.forHost`), else to the highest known rate.
    var priceFamily: String?

    init(id: String, name: String, baseURL: String, models: [String], needsKey: Bool = true, priceFamily: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.needsKey = needsKey
        self.priceFamily = priceFamily
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        baseURL = try c.decode(String.self, forKey: .baseURL)
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        needsKey = try c.decodeIfPresent(Bool.self, forKey: .needsKey) ?? true
        priceFamily = try c.decodeIfPresent(String.self, forKey: .priceFamily)
    }
}

/// A built-in family's use by subagents. Off by default for every non-primary family: a key
/// left from an old setup isn't consent to send a subagent's context there (#677 ruling).
struct BuiltInSubagentUse: Codable, Equatable, Sendable {
    var enabled: Bool = false
    /// Model ids beyond the family's three tier models, for subagents only.
    var extraModels: [String] = []

    init(enabled: Bool = false, extraModels: [String] = []) {
        self.enabled = enabled
        self.extraModels = extraModels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        extraModels = try c.decodeIfPresent([String].self, forKey: .extraModels) ?? []
    }
}

enum ProviderSlug {
    /// The built-in families' ids. A custom endpoint can't take one.
    static func id(of family: LLMProvider) -> String { family.rawValue.lowercased() }
    static var builtInIds: Set<String> { Set(LLMProvider.allCases.map(id(of:))) }

    /// The dict entry for an endpoint's key. Prefixed, so no slug can name `GEMINI_API_KEY` or
    /// any other entry the dict already holds.
    static func secretName(_ id: String) -> String { "PROVIDER_\(id)_API_KEY" }
    /// The origin the key was entered for. The defaults domain can be written by one approved
    /// command, so a key is only ever sent to this origin (#677 review).
    static func originName(_ id: String) -> String { "PROVIDER_\(id)_ORIGIN" }

    /// Letters, digits and `. _ : / -`, up to 100: model ids reach an agent-facing description.
    static func isValidModelId(_ id: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:/-"))
        return (1...100).contains(id.count) && id.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
    }

    /// Why `id` can't name an endpoint, or nil.
    static func problem(with id: String, taken: Set<String> = []) -> String? {
        guard (1...32).contains(id.count) else { return "An id is 1 to 32 characters." }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard id.allSatisfy(allowed.contains), id.first != "-", id.last != "-" else {
            return "An id uses lowercase letters, digits and inner hyphens only, for example `deepseek` or `local-ollama`."
        }
        if builtInIds.contains(id) { return "`\(id)` is a built-in family's id." }
        if taken.contains(id) { return "Another provider already uses `\(id)`." }
        return nil
    }
}

enum EndpointURL {
    /// Why `text` can't be an endpoint's base URL, or nil: https only, except a loopback host.
    static func problem(with text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed), let scheme = c.scheme?.lowercased(),
              let host = c.host, !host.isEmpty else {
            return "Enter a full URL, for example `https://api.deepseek.com/v1`."
        }
        if c.user != nil || c.password != nil { return "A URL with a user name or password in it isn't allowed." }
        if scheme == "https" { return nil }
        if scheme == "http", isLoopback(host) { return nil }
        return "Only https is allowed, except for a server on this Mac (localhost, 127.0.0.1 or ::1)."
    }

    /// Exactly one of the three loopback spellings: no suffix, no mapped address, no 0.0.0.0.
    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h == "127.0.0.1" || h == "::1"
    }

    static func isLoopbackURL(_ text: String) -> Bool {
        guard let host = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host else { return false }
        return isLoopback(host)
    }

    /// `scheme://host:port`, the port spelled out, or nil for a URL `problem(with:)` refuses.
    static func origin(of text: String) -> String? {
        guard problem(with: text) == nil,
              let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased() else { return nil }
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}

/// Where one subagent's calls go. Built only by `ConfigManager.subagentRoute`, from Settings.
struct ProviderRoute: Sendable, Equatable, CustomStringConvertible {
    enum Target: Sendable, Equatable {
        case builtIn(LLMProvider)
        case endpoint(baseURL: String, apiKey: String)
    }
    let providerId: String
    let target: Target
    let model: String

    /// Never the key.
    var description: String { "ProviderRoute(\(providerId), \(model))" }

    var isEndpoint: Bool { if case .endpoint = target { return true } else { return false } }
}

/// One provider as a subagent could see it: the primary, a built-in family, or an endpoint.
struct RegisteredProvider: Equatable, Sendable {
    let id: String
    let name: String
    let isPrimary: Bool
    let isBuiltIn: Bool
    /// Has a key (or needs none).
    let hasKey: Bool
    /// An endpoint whose address changed since its key was entered: its key is never sent.
    let originChanged: Bool
    /// The primary, a keyed built-in with its switch on, or a keyed endpoint.
    let usable: Bool
    let models: [String]
}

enum SubagentRouteRefusal: Error, Equatable {
    case unknownProvider(String, usable: [String])
    case notEnabled(String)
    case noKey(String, isBuiltIn: Bool)
    case noModels(String)
    case originChanged(String)
    case unknownModel(String, provider: String, models: [String])

    /// One sentence naming what is configured (Fork D). Never a key.
    var message: String {
        switch self {
        case .unknownProvider(let id, let usable):
            return "No provider `\(id)`. Usable by subagents: \(usable.joined(separator: ", "))."
        case .notEnabled(let name):
            return "\(name) is configured but not enabled for subagents: Settings → Models → Subagent providers."
        case .noKey(let id, let isBuiltIn):
            return isBuiltIn
                ? "Provider `\(id)` has no key set. Add one in Settings → Models."
                : "Provider `\(id)` has no key set. Add one in Settings → Models → Subagent providers."
        case .originChanged(let id):
            return "Provider `\(id)`'s address changed since its key was entered; re-enter the key in Settings → Models → Subagent providers."
        case .noModels(let id):
            return "Provider `\(id)` lists no models. Add an exact model id in Settings → Models → Subagent providers."
        case .unknownModel(let model, let provider, let models):
            return "Model `\(model)` isn't in provider `\(provider)`'s list: \(models.joined(separator: ", ")). Use an exact id."
        }
    }
}

/// Removes a secret from text that may be shown or logged: a provider can echo the key it was
/// sent in an error body.
enum SecretScrub {
    static func scrub(_ text: String, _ secrets: [String]) -> String {
        secrets.filter { $0.count >= 8 }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }

    static func scrub(_ data: Data, _ secrets: [String]) -> Data {
        guard secrets.contains(where: { $0.count >= 8 }), let text = String(data: data, encoding: .utf8) else { return data }
        return Data(scrub(text, secrets).utf8)
    }
}

extension ConfigManager {
    static let subagentEndpointsKey = "SUBAGENT_PROVIDERS"
    static let subagentBuiltInsKey = "SUBAGENT_BUILTINS"

    /// The custom endpoints. An entry that doesn't decode is dropped on its own and counted in
    /// `undecodableSubagentEndpoints`, never the whole list (the Invariant 1 shape).
    var subagentEndpoints: [ProviderEndpoint] {
        get { Self.decodeEndpoints(Data(guardedBlob(.subagentProviders).utf8)).endpoints }
        set {
            let json = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            setGuardedBlob(.subagentProviders, json)
        }
    }

    /// #239 3c: rates typed in Settings, guarded. The app hands them to `PriceBook.shared` at launch
    /// and on each save in Settings; nothing here touches it, so a test's own config can't.
    var subagentRates: [String: TokenRates] {
        get { TypedRates.decode(guardedBlob(.subagentRates)) }
        set { setGuardedBlob(.subagentRates, TypedRates.encode(newValue.filter { PriceGuards.fieldsValid($0.value) })) }
    }

    var undecodableSubagentEndpoints: Int {
        Self.decodeEndpoints(Data(guardedBlob(.subagentProviders).utf8)).dropped
    }

    static func decodeEndpoints(_ data: Data?) -> (endpoints: [ProviderEndpoint], dropped: Int) {
        guard let data, !data.isEmpty else { return ([], 0) }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return ([], 1) }
        var endpoints: [ProviderEndpoint] = []
        var dropped = 0
        for item in raw {
            guard let one = try? JSONSerialization.data(withJSONObject: item),
                  let endpoint = try? JSONDecoder().decode(ProviderEndpoint.self, from: one),
                  ProviderSlug.problem(with: endpoint.id, taken: Set(endpoints.map(\.id))) == nil,
                  EndpointURL.problem(with: endpoint.baseURL) == nil,
                  endpoint.needsKey || EndpointURL.isLoopbackURL(endpoint.baseURL) else {
                dropped += 1
                continue
            }
            endpoints.append(endpoint)
        }
        return (endpoints, dropped)
    }

    /// Each built-in family's subagent use, keyed by `LLMProvider` raw value.
    var subagentBuiltIns: [String: BuiltInSubagentUse] {
        get {
            let text = guardedBlob(.subagentBuiltIns)
            guard !text.isEmpty else { return [:] }
            return (try? JSONDecoder().decode([String: BuiltInSubagentUse].self, from: Data(text.utf8))) ?? [:]
        }
        set {
            let json = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            setGuardedBlob(.subagentBuiltIns, json)
        }
    }

    /// Whether `family` has what it needs to authenticate, by the same rule as the primary.
    func isConfigured(family: LLMProvider) -> Bool {
        Self.isConfigured(provider: family.rawValue, geminiAuthMode: geminiAuthMode, geminiAPIKey: geminiAPIKey,
                          anthropicAuthMode: anthropicAuthMode, anthropicAPIKey: anthropicAPIKey,
                          anthropicVertexProject: anthropicVertexProject, openAIAPIKey: openAIAPIKey)
    }

    /// A family's three tier models, read from its own fields (the primary's resolver reads only
    /// the primary's, and it isn't changed here).
    func tierModels(of family: LLMProvider) -> [String] {
        switch family {
        case .anthropic: [anthropicModelEasy, anthropicModelMedium, anthropicModelHard]
        case .openai:    [openaiModelEasy, openaiModelMedium, openaiModelHard]
        case .gemini:    [geminiModelEasy, geminiModelMedium, geminiModelHard]
        }
    }

    private static func cleaned(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { ProviderSlug.isValidModelId($0) && seen.insert($0).inserted }
    }

    /// The registry: the primary, every built-in family, then the custom endpoints.
    func providerRegistry(keychain explicitKeychain: KeychainManager? = nil) -> [RegisteredProvider] {
        let keychain = explicitKeychain ?? guardedKeychain ?? .shared
        let primary = LLMProvider(rawValue: primaryProvider) ?? .gemini
        let builtIns = subagentBuiltIns
        let secrets = secretsSnapshot(keychain)
        let families = LLMProvider.allCases.map { family -> RegisteredProvider in
            let isPrimary = family == primary
            let use = builtIns[family.rawValue] ?? BuiltInSubagentUse()
            let keyed = isConfigured(family: family)
            return RegisteredProvider(id: ProviderSlug.id(of: family), name: family.rawValue, isPrimary: isPrimary,
                                      isBuiltIn: true, hasKey: keyed, originChanged: false,
                                      usable: isPrimary || (keyed && use.enabled),
                                      models: Self.cleaned(tierModels(of: family) + use.extraModels))
        }
        let endpoints = subagentEndpoints.map { e -> RegisteredProvider in
            let keyed = !e.needsKey || !(secrets[ProviderSlug.secretName(e.id)] ?? "").isEmpty
            let moved = e.needsKey && keyed && secrets[ProviderSlug.originName(e.id)] != EndpointURL.origin(of: e.baseURL)
            return RegisteredProvider(id: e.id, name: e.name, isPrimary: false, isBuiltIn: false,
                                      hasKey: keyed, originChanged: moved, usable: keyed && !moved,
                                      models: Self.cleaned(e.models))
        }
        return families + endpoints
    }

    /// True when a subagent could be sent somewhere other than the primary: the gate for
    /// declaring `invoke_subagent`'s `provider`/`model` (Invariant 6). A leftover key with its
    /// switch off doesn't count.
    func hasUsableSubagentProviders(keychain explicitKeychain: KeychainManager? = nil) -> Bool {
        let keychain = explicitKeychain ?? guardedKeychain ?? .shared
        return providerRegistry(keychain: keychain).contains { $0.usable && !$0.isPrimary }
    }

    /// Where a subagent naming `providerId` (and `model`, or the provider's default) runs, or why
    /// it can't. Refuses rather than falling back: a lens that quietly ran on the parent's model
    /// is the wrong review with the right label (Fork D).
    func subagentRoute(provider providerId: String, model requested: String?, tier: ModelTier = .medium,
                       keychain explicitKeychain: KeychainManager? = nil) -> Result<ProviderRoute, SubagentRouteRefusal> {
        let keychain = explicitKeychain ?? guardedKeychain ?? .shared
        let registry = providerRegistry(keychain: keychain)
        let usable = registry.filter(\.usable).map { $0.isPrimary ? "\($0.id) (primary)" : $0.id }
        guard let entry = registry.first(where: { $0.id == providerId }) else {
            return .failure(.unknownProvider(providerId, usable: usable))
        }
        guard entry.hasKey else { return .failure(.noKey(entry.id, isBuiltIn: entry.isBuiltIn)) }
        guard !entry.originChanged else { return .failure(.originChanged(entry.id)) }
        guard entry.usable else { return .failure(.notEnabled(entry.name)) }
        guard !entry.models.isEmpty else { return .failure(.noModels(entry.id)) }

        let model: String
        if let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            guard entry.models.contains(requested) else {
                return .failure(.unknownModel(requested, provider: entry.id, models: entry.models))
            }
            model = requested
        } else if entry.isBuiltIn, let family = LLMProvider(rawValue: entry.name) {
            let tiers = tierModels(of: family)
            let index = tier == .easy ? 0 : tier == .hard ? 2 : 1
            model = tiers[index].isEmpty ? entry.models[0] : tiers[index]
        } else {
            model = entry.models[0]
        }

        if entry.isBuiltIn, let family = LLMProvider(rawValue: entry.name) {
            return .success(ProviderRoute(providerId: entry.id, target: .builtIn(family), model: model))
        }
        guard let endpoint = subagentEndpoints.first(where: { $0.id == entry.id }) else {
            return .failure(.unknownProvider(providerId, usable: usable))
        }
        let key = secretsSnapshot(keychain)[ProviderSlug.secretName(endpoint.id)] ?? ""
        return .success(ProviderRoute(providerId: endpoint.id,
                                      target: .endpoint(baseURL: endpoint.baseURL, apiKey: key), model: model))
    }

    // MARK: Endpoint edits (Settings only)

    /// Adds or replaces `endpoint`, storing `key` when given (nil keeps the stored one). Throws a
    /// sentence when the id or URL is refused.
    func saveSubagentEndpoint(_ endpoint: ProviderEndpoint, key: String?, replacing oldId: String? = nil,
                              keychain explicitKeychain: KeychainManager? = nil) throws {
        let keychain = explicitKeychain ?? guardedKeychain ?? .shared
        var list = subagentEndpoints
        let others = Set(list.map(\.id)).subtracting([oldId ?? endpoint.id])
        if let problem = ProviderSlug.problem(with: endpoint.id, taken: others) { throw APIError(message: problem) }
        if let problem = EndpointURL.problem(with: endpoint.baseURL) { throw APIError(message: problem) }
        if !endpoint.needsKey, !EndpointURL.isLoopbackURL(endpoint.baseURL) {
            throw APIError(message: "Only a server on this Mac can go without a key.")
        }
        var clean = endpoint
        clean.baseURL = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.models = Self.cleaned(endpoint.models)
        if clean.name.trimmingCharacters(in: .whitespaces).isEmpty { clean.name = clean.id }

        var secrets = keychain.loadSecrets()
        if let oldId, oldId != clean.id {
            // A rename moves the key with its origin, so a moved address still needs a re-entry.
            let movedKey = secrets.removeValue(forKey: ProviderSlug.secretName(oldId))
            let movedOrigin = secrets.removeValue(forKey: ProviderSlug.originName(oldId))
            if key == nil {
                secrets[ProviderSlug.secretName(clean.id)] = movedKey
                secrets[ProviderSlug.originName(clean.id)] = movedOrigin
            }
        }
        if let key {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            secrets[ProviderSlug.secretName(clean.id)] = trimmed.isEmpty ? nil : trimmed
            secrets[ProviderSlug.originName(clean.id)] = trimmed.isEmpty ? nil : EndpointURL.origin(of: clean.baseURL)
        }
        keychain.saveSecrets(secrets); secretsCache = nil

        list.removeAll { $0.id == (oldId ?? clean.id) }
        list.append(clean)
        subagentEndpoints = list
    }

    /// Removes an endpoint and deletes its key from the dict.
    func removeSubagentEndpoint(id: String, keychain explicitKeychain: KeychainManager? = nil) {
        let keychain = explicitKeychain ?? guardedKeychain ?? .shared
        subagentEndpoints = subagentEndpoints.filter { $0.id != id }
        var secrets = keychain.loadSecrets()
        let hadKey = secrets.removeValue(forKey: ProviderSlug.secretName(id)) != nil
        let hadOrigin = secrets.removeValue(forKey: ProviderSlug.originName(id)) != nil
        if hadKey || hadOrigin { keychain.saveSecrets(secrets); secretsCache = nil }
    }

    func subagentEndpointHasKey(_ id: String, keychain explicitKeychain: KeychainManager? = nil) -> Bool {
        let keychain = explicitKeychain ?? guardedKeychain ?? .shared
        return !(secretsSnapshot(keychain)[ProviderSlug.secretName(id)] ?? "").isEmpty
    }

    /// The stored key, for Check only. Never displayed.
    func subagentEndpointKey(_ id: String, keychain explicitKeychain: KeychainManager? = nil) -> String {
        let keychain = explicitKeychain ?? guardedKeychain ?? .shared
        return secretsSnapshot(keychain)[ProviderSlug.secretName(id)] ?? ""
    }

    func setSubagentUse(_ use: BuiltInSubagentUse, for family: LLMProvider) {
        var all = subagentBuiltIns
        all[family.rawValue] = BuiltInSubagentUse(enabled: use.enabled, extraModels: Self.cleaned(use.extraModels))
        subagentBuiltIns = all
    }
}

/// The session a routed endpoint call uses: it follows no redirect. A 307 or 308 would resend
/// the POST body, a subagent's whole context, to wherever it points (#677 review).
final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let session = URLSession(configuration: .default, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

extension ConfigManager {
    /// Where Settings' Check may send a request for endpoint `id`: its own base URL, with its key
    /// only when the key was entered for that origin.
    func checkTarget(for id: String, keychain explicitKeychain: KeychainManager? = nil) -> Result<(baseURL: String, apiKey: String), SubagentRouteRefusal> {
        let keychain = explicitKeychain ?? guardedKeychain ?? .shared
        guard let endpoint = subagentEndpoints.first(where: { $0.id == id }) else {
            return .failure(.unknownProvider(id, usable: []))
        }
        guard endpoint.needsKey else { return .success((endpoint.baseURL, "")) }
        let secrets = secretsSnapshot(keychain)
        let key = secrets[ProviderSlug.secretName(id)] ?? ""
        guard !key.isEmpty else { return .failure(.noKey(id, isBuiltIn: false)) }
        guard secrets[ProviderSlug.originName(id)] == EndpointURL.origin(of: endpoint.baseURL) else {
            return .failure(.originChanged(id))
        }
        return .success((endpoint.baseURL, key))
    }
}
