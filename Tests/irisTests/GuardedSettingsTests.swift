import Testing
import Foundation
import Security
@testable import IrisKit

/// #678: a setting that guards spend, where data goes, or the safety switches can't be changed by
/// a host command's `defaults write`. Each test has its own suite and its own in-memory keychain
/// (Invariant 7); none touches `ConfigManager.shared` or the process's secrets.
@MainActor
@Suite("Guarded settings (#678)")
struct GuardedSettingsTests {
    private func harness() -> (UserDefaults, KeychainManager, String) {
        let suite = "iris-guarded-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return (store, KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true), suite)
    }

    private func teardown(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        IrisDefaults.removeSuiteFile(named: suite, in: IrisDefaults.preferencesDirectory)
    }

    private var protective: [GuardedKey: String] {
        Dictionary(uniqueKeysWithValues: GuardedKey.allCases.map { ($0, $0.protective) })
    }

    // MARK: the decision, pure

    @Test("the upgrade carries a value only if it's no looser than built-in, and says which it reset")
    func upgrade() {
        let defaults = ["JOB_DAILY_TOKEN_BUDGET": "1000",          // stricter: carried
                        "MAX_GOAL_ITERATIONS": "500",              // looser: reset
                        "OPENAI_BASE_URL": "https://proxy.example.com/v1",  // looser: reset
                        "ENABLE_PROMPT_INJECTION_PROTECTION": "false",      // looser: reset
                        "ENABLE_VIBECOP": "true", "ENABLE_SANDBOXING": "false"]  // carried either way
        let load = GuardedSettings.load(item: .read(["GEMINI_API_KEY": "k"]), defaults: defaults, defaultsMarker: false)
        #expect(load.state == .normal)
        #expect(load.values[.jobDailyTokenBudget] == "1000")
        #expect(load.values[.maxGoalIterations] == "50")
        #expect(load.values[.openAIBaseURL] == "")
        #expect(load.values[.enablePromptInjectionProtection] == "true")
        #expect(load.values[.enableVibecop] == "true" && load.values[.enableSandboxing] == "false")
        #expect(load.write?["GEMINI_API_KEY"] == "k", "the keys already there are kept")
        #expect(load.write?[GuardedSettings.markerKey] == "1")
        #expect(Set(load.removeFromDefaults) == Set(defaults.keys))
        #expect(load.setDefaultsMarker)
        #expect(load.notices == [GuardedSettings.upgradeNotice + " These were looser than Iris's built-in values and went back to them: OPENAI_BASE_URL, MAX_GOAL_ITERATIONS, ENABLE_PROMPT_INJECTION_PROTECTION."])
        #expect(!load.notices.joined().contains("proxy.example.com"), "keys are named, never values")
    }

    @Test("an install with no item at all gets one at the upgrade, with its values")
    func upgradeWithNoItem() {
        let load = GuardedSettings.load(item: .read([:]), defaults: ["JOB_PER_RUN_TOKEN_BUDGET": "10"], defaultsMarker: false)
        #expect(load.state == .normal)
        #expect(load.notices == [GuardedSettings.upgradeNotice], "said even with nothing reset")
        #expect(load.write?["JOB_PER_RUN_TOKEN_BUDGET"] == "10" && load.write?[GuardedSettings.markerKey] == "1")
    }

    @Test("a replay of the upgrade (item and defaults marker both deleted) is announced again")
    func replayAnnounced() {
        let (store, keychain, suite) = harness(); defer { teardown(suite) }
        let first = ConfigManager(store: store, guardedSecrets: keychain)
        #expect(first.takeGuardedNotices() == [GuardedSettings.upgradeNotice])
        first.enableSandboxing = true
        // Two silent shell steps: `security delete-generic-password`, `defaults delete … GUARDED_SETTINGS_V1`.
        keychain.saveSecrets([:])
        store.removeObject(forKey: GuardedSettings.markerKey)
        let replayed = ConfigManager(store: store, guardedSecrets: keychain)
        #expect(!replayed.enableSandboxing, "the documented limit: back to built-in")
        #expect(replayed.takeGuardedNotices() == [GuardedSettings.upgradeNotice], "but never silently")
    }

    @Test("after the upgrade, a defaults write is ignored and named once")
    func defaultsWriteIgnored() {
        let item = [GuardedSettings.markerKey: "1", "JOB_DAILY_TOKEN_BUDGET": "1000", "ENABLE_SANDBOXING": "true"]
        let load = GuardedSettings.load(item: .read(item),
                                        defaults: ["JOB_DAILY_TOKEN_BUDGET": "99999999", "ENABLE_SANDBOXING": "false"],
                                        defaultsMarker: true)
        #expect(load.values[.jobDailyTokenBudget] == "1000" && load.values[.enableSandboxing] == "true")
        #expect(load.write == nil)
        #expect(load.notices == ["A setting was changed outside Settings and was not applied: JOB_DAILY_TOKEN_BUDGET, ENABLE_SANDBOXING. Change it in Settings if you meant to."])
        #expect(Set(load.removeFromDefaults) == ["JOB_DAILY_TOKEN_BUDGET", "ENABLE_SANDBOXING"])
    }

    @Test("an item gone after the upgrade gives the protective values and writes nothing")
    func missingAfterUpgrade() {
        let load = GuardedSettings.load(item: .read(["GEMINI_API_KEY": "planted"]),
                                        defaults: ["ENABLE_SANDBOXING": "false"], defaultsMarker: true)
        #expect(load.state == .missing)
        #expect(load.values == protective)
        #expect(load.values[.enableSandboxing] == "true" && load.values[.enableVibecop] == "true")
        #expect(load.values[.mainAgentSandboxDefault] == "sandboxed" && load.values[.openAIBaseURL] == "")
        #expect(load.write == nil, "never written into what may be someone else's item")
        #expect(load.notices.count == 1 && load.notices[0].contains("missing"))
    }

    @Test("an unreadable item gives the protective values and is never written")
    func unreadable() {
        let load = GuardedSettings.load(item: .unreadable(errSecAuthFailed),
                                        defaults: ["JOB_DAILY_TOKEN_BUDGET": "99999999"], defaultsMarker: true)
        #expect(load.state == .unreadable(errSecAuthFailed))
        #expect(load.values == protective)
        #expect(load.write == nil && load.removeFromDefaults.isEmpty)
        #expect(load.notices.count == 1 && load.notices[0].contains("couldn't read"))
    }

    @Test("a stored value that fails its type check is protective, not trusted")
    func invalidStoredValue() {
        let item = [GuardedSettings.markerKey: "1", "ENABLE_SANDBOXING": "maybe", "JOB_DAILY_TOKEN_BUDGET": "-5"]
        let load = GuardedSettings.load(item: .read(item), defaults: [:], defaultsMarker: true)
        #expect(load.values[.enableSandboxing] == "true")
        #expect(load.values[.jobDailyTokenBudget] == GuardedKey.jobDailyTokenBudget.protective)
    }

    // MARK: through ConfigManager

    @Test("a Settings change applies and persists; a later defaults write changes nothing")
    func settingsApplyDefaultsDont() {
        let (store, keychain, suite) = harness(); defer { teardown(suite) }
        let first = ConfigManager(store: store, guardedSecrets: keychain)
        #expect(first.guardedState == .normal)
        first.jobDailyTokenBudget = 1234
        first.enableSandboxing = true
        #expect(keychain.loadSecrets()["JOB_DAILY_TOKEN_BUDGET"] == "1234")
        #expect(store.object(forKey: "JOB_DAILY_TOKEN_BUDGET") == nil, "nothing guarded is written to defaults")

        // One approved `defaults write` from a host command.
        store.set(99_999_999, forKey: "JOB_DAILY_TOKEN_BUDGET")
        store.set(false, forKey: "ENABLE_SANDBOXING")
        store.set("https://collector.example.com", forKey: "OPENAI_BASE_URL")
        let next = ConfigManager(store: store, guardedSecrets: keychain)
        #expect(next.jobDailyTokenBudget == 1234)
        #expect(next.enableSandboxing)
        #expect(next.openAIBaseURL == "")
        #expect(next.takeGuardedNotices().first?.contains("not applied") == true)
        #expect(next.takeGuardedNotices().isEmpty, "said once")
    }

    @Test("an unreadable item: protective values, and neither a setting nor a key is written over it")
    func unreadableNeverWritten() {
        let (store, keychain, suite) = harness(); defer { teardown(suite) }
        _ = ConfigManager(store: store, guardedSecrets: keychain)
        keychain.saveSecrets(keychain.loadSecrets().merging(["ENABLE_SANDBOXING": "false"]) { $1 })
        let before = keychain.loadSecrets()

        keychain.simulateReadFailure(errSecAuthFailed)   // the person clicked Deny
        let config = ConfigManager(store: store, guardedSecrets: keychain)
        #expect(config.guardedState == .unreadable(errSecAuthFailed))
        #expect(config.enableSandboxing && config.enableVibecop && config.enableAdvancedPromptInjectionProtection)
        #expect(config.mainAgentSandboxDefault == .sandboxed)
        #expect(config.refusesHostWithoutRuntime)
        config.jobDailyTokenBudget = 7
        keychain.saveSecrets(["GEMINI_API_KEY": "would-replace-everything"])
        keychain.simulateReadFailure(nil)
        #expect(keychain.loadSecrets() == before, "the item is exactly as it was")
    }

    @Test("an item deleted after the upgrade: protective values, and the next Settings change saves all of them")
    func deletedThenChanged() {
        let (store, keychain, suite) = harness(); defer { teardown(suite) }
        _ = ConfigManager(store: store, guardedSecrets: keychain)
        keychain.saveSecrets([:])               // a silent `security delete-generic-password`
        store.set(false, forKey: "ENABLE_VIBECOP")
        let config = ConfigManager(store: store, guardedSecrets: keychain)
        #expect(config.guardedState == .missing)
        #expect(config.enableVibecop && config.enableSandboxing)
        #expect(config.refusesHostWithoutRuntime)

        config.jobPerRunTokenBudget = 500
        let saved = keychain.loadSecrets()
        #expect(saved["JOB_PER_RUN_TOKEN_BUDGET"] == "500")
        #expect(saved["ENABLE_SANDBOXING"] == "true" && saved["ENABLE_VIBECOP"] == "true",
                "the untouched keys keep the protective values the person was shown")
        #expect(!config.refusesHostWithoutRuntime, "saved again: the refusal ends without a relaunch")
        #expect(ConfigManager(store: store, guardedSecrets: keychain).guardedState == .normal)
    }

    @Test("a fresh install with nothing anywhere starts at the built-in values, item created")
    func freshInstall() {
        let (store, keychain, suite) = harness(); defer { teardown(suite) }
        let config = ConfigManager(store: store, guardedSecrets: keychain)
        #expect(config.guardedState == .normal && config.takeGuardedNotices() == [GuardedSettings.upgradeNotice])
        #expect(!config.enableVibecop && !config.enableSandboxing && config.enableAdvancedPromptInjectionProtection)
        #expect(config.jobDailyTokenBudget == ConfigManager.JobDefaults.dailyTokenBudget)
        #expect(keychain.loadSecrets()[GuardedSettings.markerKey] == "1")
        #expect(store.bool(forKey: GuardedSettings.markerKey))
        #expect(!config.refusesHostWithoutRuntime)
    }

    @Test("the upgrade notice reaches the chat at launch")
    func noticeReachesTheChat() throws {
        let (defaults, keychain, suite) = harness(); defer { teardown(suite) }
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned,
                             guardedConfig: ConfigManager(store: defaults, guardedSecrets: keychain))
        let id = try #require(state.selectedConversationId)
        #expect(state.conversations.first { $0.id == id }?.messages
            .contains { $0.role == .system && $0.content == GuardedSettings.upgradeNotice } == true)
    }

    @Test("a replayed upgrade notice is posted again where the first one already is; other notices still dedup")
    func upgradeNoticeNeverDeduplicated() throws {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, emitLaunchNotices: false)
        let id = state.createNewConversation(select: true)
        func count(_ text: String) -> Int {
            state.conversations.first { $0.id == id }?.messages.filter { $0.content == text }.count ?? 0
        }
        let other = "A setting was changed outside Settings and was not applied: OPENAI_BASE_URL. Change it in Settings if you meant to."
        state.postGuardedNotices([GuardedSettings.upgradeNotice, other], to: id)
        state.postGuardedNotices([GuardedSettings.upgradeNotice, other], to: id)
        #expect(count(GuardedSettings.upgradeNotice) == 2)
        #expect(count(other) == 1)
    }

    // MARK: the dialog hint

    @Test("the approval dialog warns when a command names Iris's keychain service or defaults domain")
    func approvalHint() {
        #expect(GuardedSettings.approvalWarning(for: "security delete-generic-password -s com.iris.secrets.dev") != nil)
        #expect(GuardedSettings.approvalWarning(for: "defaults write com.bnaylor.iris.dev JOB_DAILY_TOKEN_BUDGET 1") != nil)
        #expect(GuardedSettings.approvalWarning(for: "DEFAULTS WRITE COM.BNAYLOR.IRIS X 1") != nil)
        #expect(GuardedSettings.approvalWarning(for: "defaults delete \"$D\" GUARDED_SETTINGS_V1") != nil)
        #expect(GuardedSettings.approvalWarning(for: "ls -la ~/src") == nil)
    }
}
