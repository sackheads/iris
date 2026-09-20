import Testing
import Foundation
@testable import iris

/// Persisted app state must not reach the developer's real `UserDefaults` from a test run.
/// Before this, `AppState` wrote conversations to `UserDefaults.standard` unconditionally and
/// 344 test conversations had accumulated on one machine (#121). Persistence now goes through
/// `markChanged`/the conversation store, which tests get as an in-memory database.
@MainActor
@Suite("Defaults isolation")
struct DefaultsIsolationTests {
    @Test("the backing store is volatile under test, not the user's real defaults")
    func storeIsVolatile() {
        #expect(IrisDefaults.store !== UserDefaults.standard,
                "under test the store must be a throwaway suite")
    }

    @Test("saving conversations touches neither the real UserDefaults nor the real store file")
    func conversationsDoNotLeak() {
        let key = LegacyConversationBlob.key
        let before = UserDefaults.standard.data(forKey: key)
        let fileBefore = FileManager.default.fileExists(atPath: IrisPaths.standard.conversationsDB.path)
        let app = AppState()
        app.createNewConversation(id: UUID())
        app.flushSave()
        #expect(UserDefaults.standard.data(forKey: key) == before)
        #expect(FileManager.default.fileExists(atPath: IrisPaths.standard.conversationsDB.path) == fileBefore)
    }

    @Test("a fresh AppState with its own store starts empty apart from the default conversation")
    func freshStateIsClean() throws {
        let app = AppState(store: try .inMemory())
        #expect(app.conversations.count == 1)
    }

    @Test("the setup-completed flag is not flipped by a test run")
    func setupFlagDoesNotLeak() {
        // ChatView and SetupWizardView read/write HAS_COMPLETED_SETUP. A test writing it would
        // change whether the real app shows the setup wizard on next launch.
        let key = "HAS_COMPLETED_SETUP"
        let before = UserDefaults.standard.object(forKey: key) as? Bool
        IrisDefaults.store.set(true, forKey: key)
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == before)
    }
}
