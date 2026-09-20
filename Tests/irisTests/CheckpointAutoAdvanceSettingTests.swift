import Testing
import Foundation
@testable import iris

/// Invariant 7: construct an isolated ConfigManager, never mutate ConfigManager.shared.
@Suite("checkpointAutoAdvance setting (D3)")
struct CheckpointAutoAdvanceSettingTests {

    @Test("defaults to true when nothing is stored")
    func testDefaultsOn() {
        let config = ConfigManager()
        #expect(config.checkpointAutoAdvance == true)
    }

    @Test("a stored false is honoured")
    func testStoredFalseHonoured() {
        let config = ConfigManager()
        config.checkpointAutoAdvance = false
        #expect(config.checkpointAutoAdvance == false)
    }
}
