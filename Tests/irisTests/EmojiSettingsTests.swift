import Testing
import Foundation
@testable import iris

@Suite("Emoji settings")
struct EmojiSettingsTests {
    /// Each test gets its own suite so nothing it writes is visible to another test — settings
    /// leaking through the process-global store is #109, and reaching for it from a test that
    /// merely wants an isolated manager is #193.
    private func isolatedConfig() -> (ConfigManager, UserDefaults, String) {
        let name = "iris-emoji-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return (ConfigManager(store: store), store, name)
    }

    private func cleanup(_ store: UserDefaults, _ name: String) {
        store.removePersistentDomain(forName: name)
        // removePersistentDomain does not delete the backing plist on current macOS (#178).
        IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
    }

    @Test("default skin tone persists to UserDefaults")
    func persists() {
        let (config, store, name) = isolatedConfig()
        defer { cleanup(store, name) }
        config.defaultEmojiSkinTone = SkinTone.dark.rawValue
        #expect(store.integer(forKey: "DEFAULT_EMOJI_SKIN_TONE") == 6)
    }

    @Test("ConfigManager.init() reads skin tone from its backing store")
    func readsBackOnInit() {
        let name = "iris-emoji-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        defer { cleanup(store, name) }
        store.set(SkinTone.dark.rawValue, forKey: "DEFAULT_EMOJI_SKIN_TONE")
        #expect(ConfigManager(store: store).defaultEmojiSkinTone == SkinTone.dark.rawValue)
    }

    @Test("a manager with no saved tone reads the default")
    func defaultsWhenUnset() {
        let (config, store, name) = isolatedConfig()
        defer { cleanup(store, name) }
        #expect(config.defaultEmojiSkinTone == SkinTone.none.rawValue)
    }
}
