import Testing
import Foundation
@testable import iris

/// `ConfigManager()` used to isolate the *object* but not the *backing store*: `store` was a
/// static computed property returning `IrisDefaults.store`, so a test's own manager still wrote to
/// the process-global suite and raced every other suite reading the same key (#193). The seam
/// AGENTS.md advertises only works if the store is per-instance.
@Suite("ConfigManager store isolation")
struct ConfigManagerIsolationTests {
    private func suite(_ tag: String) -> (UserDefaults, String) {
        let name = "iris-config-\(tag)-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return (store, name)
    }

    private func cleanup(_ store: UserDefaults, _ name: String) {
        store.removePersistentDomain(forName: name)
        IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
    }

    @Test("two managers with two suites do not see each other's writes")
    func instancesAreIsolated() {
        let (storeA, nameA) = suite("a")
        let (storeB, nameB) = suite("b")
        defer { cleanup(storeA, nameA); cleanup(storeB, nameB) }

        let a = ConfigManager(store: storeA)
        let b = ConfigManager(store: storeB)

        a.defaultEmojiSkinTone = SkinTone.dark.rawValue
        b.defaultEmojiSkinTone = SkinTone.light.rawValue

        #expect(storeA.integer(forKey: "DEFAULT_EMOJI_SKIN_TONE") == SkinTone.dark.rawValue)
        #expect(storeB.integer(forKey: "DEFAULT_EMOJI_SKIN_TONE") == SkinTone.light.rawValue)
        #expect(ConfigManager(store: storeA).defaultEmojiSkinTone == SkinTone.dark.rawValue)
        #expect(ConfigManager(store: storeB).defaultEmojiSkinTone == SkinTone.light.rawValue)
    }

    @Test("an injected store keeps writes out of the process-global store")
    func injectedWritesDoNotReachTheGlobalStore() {
        let (store, name) = suite("global")
        defer { cleanup(store, name) }
        let key = "APPEARANCE_THEME"
        let before = IrisDefaults.store.string(forKey: key)

        let config = ConfigManager(store: store)
        config.appearanceTheme = "iris-193-sentinel"

        #expect(store.string(forKey: key) == "iris-193-sentinel")
        #expect(IrisDefaults.store.string(forKey: key) == before)
    }

    @Test("shared still resolves the process store, so a later volatile override applies")
    func sharedFollowsIrisDefaults() {
        #expect(ConfigManager.shared.store === IrisDefaults.store)
        #expect(ConfigManager().store === IrisDefaults.store)
    }
}
