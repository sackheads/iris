import Testing
import Foundation
@testable import iris

/// Persisted app state must not reach the developer's real `UserDefaults` from a test run.
/// Before this, `AppState.saveConversations` wrote to `UserDefaults.standard` unconditionally and
/// 344 test conversations had accumulated on one machine (#121).
@MainActor
@Suite("Defaults isolation")
struct DefaultsIsolationTests {
    @Test("the backing store is volatile under test, not the user's real defaults")
    func storeIsVolatile() {
        #expect(IrisDefaults.store !== UserDefaults.standard,
                "under test the store must be a throwaway suite")
    }

    @Test("saving conversations does not touch the real UserDefaults")
    func conversationsDoNotLeak() {
        let key = "iris_conversations"
        let before = UserDefaults.standard.data(forKey: key)

        let app = AppState()
        app.createNewConversation(id: UUID())   // triggers saveConversations()

        #expect(UserDefaults.standard.data(forKey: key) == before,
                "a test's conversations must not reach the user's real defaults")
    }

    @Test("a fresh AppState starts clean rather than loading prior runs' debris")
    func freshStateIsClean() {
        // Each test process gets its own suite, so nothing survives from an earlier run. This is
        // also what makes conversation counts usable as a test baseline again.
        let app = AppState()
        #expect(app.conversations.count <= 1,
                "a fresh AppState should hold at most the one conversation it creates for itself")
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
