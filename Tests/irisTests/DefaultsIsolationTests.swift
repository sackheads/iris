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

    @Test("a fresh AppState loads only the isolated store, never a prior run's debris")
    func freshStateIsClean() {
        // The per-process suite is wiped when it is created, so an earlier run can never leak in.
        // Sibling suites in THIS process share that store by design, so the bound is what the
        // store actually holds — not an absolute count. (It was `<= 1` until #62: saves were
        // starved by their own debounce, so sibling writes rarely landed and the tighter bound
        // held by accident.) No suspension point between the read and the construction, so no
        // other @MainActor test can interleave.
        let persisted = IrisDefaults.store.data(forKey: "iris_conversations")
            .flatMap { try? JSONDecoder().decode([Conversation].self, from: $0) } ?? []
        let app = AppState()
        #expect(app.conversations.count <= max(1, persisted.count),
                "a fresh AppState loaded more conversations than the isolated store holds")
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
