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

    enum Kind { case url, cap(Int), flag, sandboxPref }

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
        }
    }

    /// What a fresh install gets.
    var builtIn: String {
        switch kind {
        case .url: ""
        case .cap(let n): String(n)
        case .sandboxPref: SandboxPref.host.rawValue
        case .flag: self == .enablePromptInjectionProtection ? "true" : "false"
        }
    }

    /// What applies when the item is missing after the upgrade, or can't be read: official
    /// endpoints, built-in caps, every guard on.
    var protective: String {
        switch kind {
        case .url, .cap: builtIn
        case .flag: "true"
        case .sandboxPref: SandboxPref.sandboxed.rawValue
        }
    }

    /// The type check every stored value passes before it is used.
    func isValid(_ value: String) -> Bool {
        switch kind {
        case .url: value.isEmpty || URL(string: value)?.scheme != nil
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
        case .url: return value.isEmpty
        case .cap(let builtIn): return (Int(value) ?? 0) <= builtIn
        case .sandboxPref: return true
        case .flag: return self == .enablePromptInjectionProtection ? value == "true" : true
        }
    }
}

enum GuardedSettings {
    /// In the item: guarded values have been written here. In defaults: the upgrade has run.
    static let markerKey = "GUARDED_SETTINGS_V1"

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
                let notices = present.isEmpty ? [] : [
                    "A setting was changed outside Settings and was not applied: \(present.map(\.rawValue).joined(separator: ", ")). Change it in Settings if you meant to."]
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
        }
    }

    /// A Settings change to a guarded setting. It saves every guarded value, not just `key`, so an
    /// item rebuilt after it went missing holds the protective values the person was shown, not
    /// built-ins for the keys they didn't touch. Nothing is written over an unreadable item.
    func persistGuarded(_ key: GuardedKey, legacy: (UserDefaults) -> Void) {
        guard let keychain = guardedKeychain else { legacy(store); return }
        guard !keychain.areWritesBlocked else { return }
        var dict = keychain.loadSecrets()
        for k in GuardedKey.allCases { dict[k.rawValue] = guardedValue(k) }
        dict[GuardedSettings.markerKey] = "1"
        keychain.saveSecrets(dict)
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
