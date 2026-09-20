import Testing
import Foundation
@testable import iris

/// Invariant 7: construct an isolated ConfigManager, never mutate ConfigManager.shared.
/// Note: ConfigManager.store is a computed property returning the process-global IrisDefaults.store,
/// so instance isolation does not isolate the backing store. Mark the suite .serialized and explicitly
/// manage store state in each test to prevent races and flakes (issue #109).
@Suite("checkpointAutoAdvance setting (D3)", .serialized)
struct CheckpointAutoAdvanceSettingTests {

    @Test("defaults to true when nothing is stored")
    func testDefaultsOn() {
        // ConfigManager.store is process-global; explicitly remove the key so "nothing is stored" is true.
        IrisDefaults.store.removeObject(forKey: "CHECKPOINT_AUTO_ADVANCE")
        let config = ConfigManager()
        #expect(config.checkpointAutoAdvance == true)
    }

    @Test("a stored false is honoured")
    func testStoredFalseHonoured() {
        let config = ConfigManager()
        config.checkpointAutoAdvance = false
        #expect(config.checkpointAutoAdvance == false)
        // Clean up the store so this test does not leak into later readers in the same process.
        IrisDefaults.store.removeObject(forKey: "CHECKPOINT_AUTO_ADVANCE")
    }
}
