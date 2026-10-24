import Foundation

/// Settings that guard spend, where data goes, or the safety switches (#678). Their values live
/// in the secrets Keychain item, not the defaults domain, so one approved `defaults write` from a
/// host command changes nothing Iris uses. See docs/plans/2026-10-19-678-guarded-settings.md.
///
/// What this can't do, and the note says so: a shell can delete that item silently, and replace
/// it; Iris's next read of a replaced item prompts, and that prompt is the only detector. A Deny
/// leaves the item unreadable, which applies the protective values below and blocks every write.
enum GuardedKey: String, CaseIterable, Sendable {
    case geminiBaseURL = "GEMINI_BASE_URL"
    case anthropicBaseURL = "ANTHROPIC_BASE_URL"
    case openAIBaseURL = "OPENAI_BASE_URL"
    case jobPerRunTokenBudget = "JOB_PER_RUN_TOKEN_BUDGET"
    case jobDailyTokenBudget = "JOB_DAILY_TOKEN_BUDGET"
    case jobGlobalDailyTokenBudget = "JOB_GLOBAL_DAILY_TOKEN_BUDGET"
    case jobMaxRunsPerHour = "JOB_MAX_RUNS_PER_HOUR"
    case jobMaxRunsPerHourWatch = "JOB_MAX_RUNS_PER_HOUR_WATCH"
    case jobRunTimeoutSeconds = "JOB_RUN_TIMEOUT_SECONDS"
    case maxGoalIterations = "MAX_GOAL_ITERATIONS"
    case maxSubagentIterations = "MAX_SUBAGENT_ITERATIONS"
    case subagentTurnTimeoutSeconds = "SUBAGENT_TURN_TIMEOUT_SECONDS"
    case maxDoneGateRetries = "MAX_DONE_GATE_RETRIES"
    case maxSessionCascade = "MAX_SESSION_CASCADE"
    case loopTickCap = "LOOP_TICK_CAP"
    case vibecopTimeoutSeconds = "VIBECOP_TIMEOUT_SECONDS"
    case enableSandboxing = "ENABLE_SANDBOXING"
    case mainAgentSandboxDefault = "MAIN_AGENT_SANDBOX_DEFAULT"
    case enableVibecop = "ENABLE_VIBECOP"
    case enablePromptInjectionProtection = "ENABLE_PROMPT_INJECTION_PROTECTION"
    /// #239: the custom endpoints (where a subagent's context goes) and the built-in families'
    /// "Usable by subagents" switches, as JSON text. Empty is none.
    case subagentProviders = "SUBAGENT_PROVIDERS"
    case subagentBuiltIns = "SUBAGENT_BUILTINS"
    /// #239 3c: rates typed in Settings, JSON keyed `providerId|model` (a subagent's) or
    /// `primary|model`. Guarded because a lower rate loosens a job's budget.
    case subagentRates = "SUBAGENT_RATES"

    enum Kind { case url, cap(Int), flag, sandboxPref, blob }

    var kind: Kind {
        switch self {
        case .geminiBaseURL, .anthropicBaseURL, .openAIBaseURL: .url
        case .jobPerRunTokenBudget: .cap(ConfigManager.JobDefaults.perRunTokenBudget)
        case .jobDailyTokenBudget: .cap(ConfigManager.JobDefaults.dailyTokenBudget)
        case .jobGlobalDailyTokenBudget: .cap(ConfigManager.JobDefaults.globalDailyTokenBudget)
        case .jobMaxRunsPerHour: .cap(ConfigManager.JobDefaults.maxRunsPerHour)
        case .jobMaxRunsPerHourWatch: .cap(ConfigManager.JobDefaults.maxRunsPerHourForWatch)
        case .jobRunTimeoutSeconds: .cap(ConfigManager.JobDefaults.runTimeoutSeconds)
        case .maxGoalIterations: .cap(50)
        case .maxSubagentIterations: .cap(ConfigManager.defaultMaxSubagentIterations)
        case .subagentTurnTimeoutSeconds: .cap(ConfigManager.defaultSubagentTurnTimeoutSeconds)
        case .maxDoneGateRetries: .cap(3)
        case .maxSessionCascade: .cap(8)
        case .loopTickCap: .cap(ConfigManager.defaultLoopTickCap)
        case .vibecopTimeoutSeconds: .cap(5)
        case .enableSandboxing, .enableVibecop, .enablePromptInjectionProtection: .flag
        case .mainAgentSandboxDefault: .sandboxPref
        case .subagentProviders, .subagentBuiltIns, .subagentRates: .blob
        }
    }

    /// What a fresh install gets.
    var builtIn: String {
        switch kind {
        case .url, .blob: ""
        case .cap(let n): String(n)
        case .sandboxPref: SandboxPref.host.rawValue
        case .flag: self == .enablePromptInjectionProtection ? "true" : "false"
        }
    }

    /// What applies when the item is missing after the upgrade, or can't be read: official
    /// endpoints, built-in caps, every guard on.
    var protective: String {
        switch kind {
        case .url, .cap, .blob: builtIn
        case .flag: "true"
        case .sandboxPref: SandboxPref.sandboxed.rawValue
        }
    }

    /// The type check every stored value passes before it is used.
    func isValid(_ value: String) -> Bool {
        switch kind {
        case .url: value.isEmpty || URL(string: value)?.scheme != nil
        case .blob: value.isEmpty || (try? JSONSerialization.jsonObject(with: Data(value.utf8))) != nil
        case .cap: Int(value).map { $0 >= 0 } ?? false
        case .flag: value == "true" || value == "false"
        case .sandboxPref: SandboxPref(rawValue: value) != nil
        }
    }

    /// Whether an old defaults value may come across at the upgrade: never looser than built-in.
    /// Lower is stricter for every cap (0 is "the default"), on is stricter for every switch, a
    /// custom base URL is looser than the official one. The sandbox and Vibecop carry either way:
    /// their built-in is off, so off isn't looser than built-in.
    func carriesOver(_ value: String) -> Bool {
        guard isValid(value) else { return false }
        switch kind {
        case .url, .blob: return value.isEmpty
        case .cap(let builtIn): return (Int(value) ?? 0) <= builtIn
        case .sandboxPref: return true
        case .flag: return self == .enablePromptInjectionProtection ? value == "true" : true
        }
    }
}

enum GuardedSettings {
    /// In the item: guarded values have been written here. In defaults: the upgrade has run.
    static let markerKey = "GUARDED_SETTINGS_V1"

    /// Settings' banner, only while the item couldn't be read: an edit then lasts until Iris quits.
    static func settingsBanner(for state: State) -> String? {
        guard case .unreadable = state else { return nil }
        return "Changes here last only until Iris quits: its Keychain item couldn't be read at launch, so nothing is saved to it."
    }

    /// The item reads but isn't one Iris can decode: damaged, and never written over (#761).
    static func damagedNotice(service: String) -> String {
        "Iris's Keychain item holding its API keys and protected settings is damaged: it can be read, but not as anything Iris wrote. So Iris is using protective values (official provider addresses, built-in limits, and the sandbox, Vibecop and prompt-injection protection on) and won't save anything to that item. To start it over, quit Iris, delete the item (Keychain Access, \"\(service)\", or in Terminal: security delete-generic-password -s \(service) -a \(KeychainManager.account)), then open Iris and enter your API keys again in Settings."
    }

    static let upgradeNotice = "Iris moved its protected settings into the Keychain (first launch of this version). If you didn't just update Iris, something reset them: check Settings → Advanced (Sandboxing, Job Limits, Agent Limits) and Settings → Vibecop."

    /// The approval dialog's warning when a call's text names Iris's own keychain service or
    /// defaults domain. A string match on the text: a hint to the person, never a gate. A command
    /// that builds the name at run time gets no warning.
    static func approvalWarning(for details: String) -> String? {
        let text = details.lowercased()
        let named = ["com.iris.secrets", "com.bnaylor.iris", markerKey.lowercased()].first { text.contains($0) }
        guard let named else { return nil }
        return "This names Iris's own settings (`\(named)`). A command that changes them can change Iris's limits, guards or provider addresses. Deny it unless you meant to."
    }

    enum State: Equatable {
        case normal
        /// The upgrade ran before, and the item is now empty or has no guarded values.
        case missing
        /// The item exists but couldn't be read: a denied prompt, or damage.
        case unreadable(OSStatus)
        /// The upgrade is due, but this process doesn't announce (`--run-job` and the other
        /// headless roles), so it is left to the app: protective values for this run, nothing written.
        case deferredToApp
    }

    /// The secrets item as one launch found it: its dict (empty when there is none), or unreadable.
    enum ItemRead: Equatable {
        case read([String: String])
        case unreadable(OSStatus)
    }

    /// What one launch decided. `values` holds every guarded key.
    struct Load: Equatable {
        var values: [GuardedKey: String]
        var state: State
        var notices: [String]
        /// The dict to save into the item, or nil to leave it alone.
        var write: [String: String]?
        /// Defaults keys to delete, and whether to set the defaults marker.
        var removeFromDefaults: [String]
        var setDefaultsMarker: Bool
    }

    /// The decision for one launch, from the item and the defaults domain. Pure.
    /// - item: the secrets dict, `.read([:])` when there is none, `.unreadable` when it can't be read.
    /// - defaults: the defaults domain's guarded keys (as strings) and its marker.
    /// - mayChange: false for a process that can't announce: it changes nothing (no item write, no
    ///   marker, no defaults deletion), so a replayed upgrade can't be completed silently there
    ///   (#679 review); the app's next launch does it, and says so.
    static func load(item: ItemRead, defaults: [String: String],
                     defaultsMarker: Bool, mayChange: Bool = true) -> Load {
        var load = decide(item: item, defaults: defaults, defaultsMarker: defaultsMarker)
        guard !mayChange else { return load }
        if load.write != nil {
            let protective = Dictionary(uniqueKeysWithValues: GuardedKey.allCases.map { ($0, $0.protective) })
            load = Load(values: protective, state: .deferredToApp, notices: [], write: nil,
                        removeFromDefaults: [], setDefaultsMarker: false)
        }
        load.removeFromDefaults = []
        load.setDefaultsMarker = false
        load.notices = []
        return load
    }

    private static func decide(item: ItemRead, defaults: [String: String],
                               defaultsMarker: Bool) -> Load {
        let present = GuardedKey.allCases.filter { defaults[$0.rawValue] != nil }
        let protective = Dictionary(uniqueKeysWithValues: GuardedKey.allCases.map { ($0, $0.protective) })

        switch item {
        case .unreadable(let status) where status == errSecDecode:
            // Read, but not a dictionary Iris wrote (#761 review): nothing Iris can do will make it
            // readable, so the notice says how to start the item over.
            return Load(values: protective, state: .unreadable(status),
                        notices: [damagedNotice(service: KeychainManager.shared.resolvedService(KeychainManager.legacyService))],
                        write: nil, removeFromDefaults: [], setDefaultsMarker: false)
        case .unreadable(let status):
            return Load(values: protective, state: .unreadable(status),
                        notices: ["Iris couldn't read its protected settings in the Keychain (status \(status)), so it is using protective values: official provider addresses, built-in limits, and the sandbox, Vibecop and prompt-injection protection on. It won't change that Keychain item until it can read it. If you didn't just deny a Keychain prompt for Iris, something else may have changed the item."],
                        write: nil, removeFromDefaults: [], setDefaultsMarker: false)
        case .read(let dict):
            if dict[markerKey] == "1" {
                var values: [GuardedKey: String] = [:]
                for key in GuardedKey.allCases {
                    let stored = dict[key.rawValue]
                    values[key] = stored.flatMap { key.isValid($0) ? $0 : nil } ?? (stored == nil ? key.builtIn : key.protective)
                }
                // Every reappearing key is deleted, so it is reported once; only one whose value
                // differs from the guarded one is reported at all (#706): an older Iris writing
                // back what it read is the common case, and noticing it trains people to ignore this.
                let differing = present.filter { defaults[$0.rawValue] != values[$0] }
                let notices = differing.isEmpty ? [] : [changedOutsideNotice(differing, defaults: defaults)]
                return Load(values: values, state: .normal, notices: notices, write: nil,
                            removeFromDefaults: present.map(\.rawValue), setDefaultsMarker: !defaultsMarker)
            }
            if defaultsMarker {
                // The upgrade ran, and the item no longer holds what it wrote: deleted, or
                // replaced by something that didn't know the marker. Nothing is written back:
                // writing into a replaced item would be writing into someone else's item.
                return Load(values: protective, state: .missing,
                            notices: ["Iris's protected settings were missing from its Keychain item, so it is using protective values: official provider addresses, built-in limits, and the sandbox, Vibecop and prompt-injection protection on. Changing any of them in Settings saves them again."],
                            write: nil, removeFromDefaults: present.map(\.rawValue), setDefaultsMarker: false)
            }
            // The upgrade, once: old values come across only if no looser than built-in.
            var values: [GuardedKey: String] = [:]
            var dropped: [GuardedKey] = []
            for key in GuardedKey.allCases {
                if let old = defaults[key.rawValue] {
                    if key.carriesOver(old) { values[key] = old } else { values[key] = key.builtIn; dropped.append(key) }
                } else {
                    values[key] = key.builtIn
                }
            }
            var written = dict
            for (key, value) in values { written[key.rawValue] = value }
            written[markerKey] = "1"
            // Always said, even with nothing reset: a person who didn't just update reads this as
            // a reset (a deleted item plus a deleted marker replays this path, #679 review).
            var notice = upgradeNotice
            if !dropped.isEmpty {
                notice += " These were looser than Iris's built-in values and went back to them: \(dropped.map(\.rawValue).joined(separator: ", "))."
            }
            let notices = [notice]
            return Load(values: values, state: .normal, notices: notices, write: written,
                        removeFromDefaults: present.map(\.rawValue), setDefaultsMarker: true)
        }
    }

    /// The defaults domain's guarded keys, read as strings the way `ConfigManager` stored them.
    /// The notice for guarded keys found in defaults with a value other than the guarded one. Each
    /// is listed with the value that was ignored, except the JSON blobs (endpoints, switches,
    /// rates), which are named only. The value was written from outside Iris by definition, and
    /// the notice is a persisted message a person and the model both read, so it goes in quoted:
    /// one line, no control characters, capped, and a URL without its user info (#707 review).
    static func changedOutsideNotice(_ keys: [GuardedKey], defaults: [String: String]) -> String {
        let listed = keys.map { key -> String in
            if case .blob = key.kind { return key.rawValue }
            return "\(key.rawValue) (ignored, written outside Iris: \(shownValue(defaults[key.rawValue] ?? "", kind: key.kind)))"
        }
        return "A setting was changed outside Settings and was not applied: \(listed.joined(separator: ", ")). If you ran an older version of Iris, that's the likely cause; otherwise check Settings."
    }

    /// An ignored value as the notice shows it.
    static func shownValue(_ value: String, kind: GuardedKey.Kind) -> String {
        var value = value
        // A URL keeps only its scheme, host and path: user info (`user:secret@`) and the query and
        // fragment (`?api_key=…`) can each hold a key, whether or not the rest parses (#707 review).
        if case .url = kind {
            value = value.replacingOccurrences(of: #"(?<=://)[^/@\s]*@"#, with: "", options: .regularExpression)
            value = value.replacingOccurrences(of: #"(?s)[?#].*$"#, with: "", options: .regularExpression)
        }
        // A system notice reads to the model with Iris's own authority, so text written outside
        // Iris is neutralised as untrusted input before it goes in (#707 review, as Briefing does).
        return GateEvaluator.quoted(PromptInjectionGuard.sanitizeUntrustedInput(value)).map { "\"\($0)\"" } ?? "empty"
    }

    static func defaultsValues(_ store: UserDefaults) -> [String: String] {
        var out: [String: String] = [:]
        for key in GuardedKey.allCases {
            guard let raw = store.object(forKey: key.rawValue) else { continue }
            switch raw {
            case let s as String: out[key.rawValue] = s
            case let n as NSNumber:
                if case .flag = key.kind { out[key.rawValue] = n.boolValue ? "true" : "false" }
                else { out[key.rawValue] = n.stringValue }
            default: out[key.rawValue] = "\(raw)"
            }
        }
        return out
    }
}

extension ConfigManager {
    /// The current value of a guarded setting, as it is stored.
    func guardedValue(_ key: GuardedKey) -> String {
        switch key {
        case .geminiBaseURL: geminiBaseURL
        case .anthropicBaseURL: anthropicBaseURL
        case .openAIBaseURL: openAIBaseURL
        case .jobPerRunTokenBudget: String(jobPerRunTokenBudget)
        case .jobDailyTokenBudget: String(jobDailyTokenBudget)
        case .jobGlobalDailyTokenBudget: String(jobGlobalDailyTokenBudget)
        case .jobMaxRunsPerHour: String(jobMaxRunsPerHour)
        case .jobMaxRunsPerHourWatch: String(jobMaxRunsPerHourForWatch)
        case .jobRunTimeoutSeconds: String(jobRunTimeoutSeconds)
        case .maxGoalIterations: String(maxGoalIterations)
        case .maxSubagentIterations: String(maxSubagentIterations)
        case .subagentTurnTimeoutSeconds: String(subagentTurnTimeoutSeconds)
        case .maxDoneGateRetries: String(maxDoneGateRetries)
        case .maxSessionCascade: String(maxSessionCascade)
        case .loopTickCap: String(loopTickCap)
        case .vibecopTimeoutSeconds: String(vibecopTimeoutSeconds)
        case .enableSandboxing: enableSandboxing ? "true" : "false"
        case .mainAgentSandboxDefault: mainAgentSandboxDefault.rawValue
        case .enableVibecop: enableVibecop ? "true" : "false"
        case .enablePromptInjectionProtection: enableAdvancedPromptInjectionProtection ? "true" : "false"
        case .subagentProviders, .subagentBuiltIns, .subagentRates: guardedBlob(key)
        }
    }

    /// A Settings change to a guarded setting. It saves every guarded value, not just `key`, so an
    /// item rebuilt after it went missing holds the protective values the person was shown, not
    /// built-ins for the keys they didn't touch. Nothing is written over an unreadable item.
    func persistGuarded(_ key: GuardedKey, legacy: (UserDefaults) -> Void) {
        guard let keychain = guardedKeychain else { legacy(store); return }
        guard !keychain.areWritesBlocked else { return }
        let values = Dictionary(uniqueKeysWithValues: GuardedKey.allCases.map { ($0.rawValue, guardedValue($0)) })
        keychain.updateSecrets { dict in
            dict.merge(values) { $1 }
            dict[GuardedSettings.markerKey] = "1"
        }
        secretsCache = nil
        // The item holds every guarded value again, so the refusal and the notice stop applying.
        if guardedState == .missing { guardedState = .normal }
    }

    /// When the guarded settings fell back to protective values, a command meant for the
    /// sandbox never falls back to the host: with no container runtime it is refused.
    var refusesHostWithoutRuntime: Bool { guardedState != .normal }

    /// The launch notices, handed over once.
    func takeGuardedNotices() -> [String] {
        defer { guardedNotices = [] }
        return guardedNotices
    }
}

extension ConfigManager {
    /// A blob-kind guarded value (#239's endpoints and switches), which has no stored property:
    /// read from the item each time. Protective (none) unless the item read normally at launch.
    func guardedBlob(_ key: GuardedKey) -> String {
        guard let keychain = guardedKeychain else { return store.string(forKey: key.rawValue) ?? "" }
        guard guardedState == .normal else { return "" }
        let value = secretsSnapshot(keychain)[key.rawValue] ?? ""
        return key.isValid(value) ? value : ""
    }

    /// Saves a blob-kind guarded value with every other guarded value, as `persistGuarded` does.
    func setGuardedBlob(_ key: GuardedKey, _ value: String) {
        guard let keychain = guardedKeychain else { store.set(value, forKey: key.rawValue); return }
        guard !keychain.areWritesBlocked else { return }
        let values = Dictionary(uniqueKeysWithValues: GuardedKey.allCases.map { ($0.rawValue, guardedValue($0)) })
        keychain.updateSecrets { dict in
            dict.merge(values) { $1 }
            dict[key.rawValue] = value
            dict[GuardedSettings.markerKey] = "1"
        }
        secretsCache = nil
        if guardedState == .missing { guardedState = .normal }
    }

    /// The secrets item for reads: cached for this manager's own keychain, read once, and empty
    /// when the item couldn't be read at launch (#678), so no other-family route can come of it.
    /// The cache lives as long as this manager, which for `shared` is the process: a key changed
    /// from outside Iris (another process, the `security` tool) is seen only after a relaunch or a
    /// write through this manager (#697 review).
    func secretsSnapshot(_ keychain: KeychainManager) -> [String: String] {
        guard keychain === guardedKeychain else { return keychain.loadSecrets() }
        if case .unreadable = guardedState { return [:] }
        if let secretsCache { return secretsCache }
        let read = keychain.loadSecrets()
        secretsCache = read
        return read
    }
}
