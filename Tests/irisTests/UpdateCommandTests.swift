import Testing
@testable import IrisKit

@Suite("/update command")
@MainActor
struct UpdateCommandTests {
    @Test("dev builds say updates are off")
    func devReply() {
        #expect(AppState.updateCommandReply(updater: nil) == "Updates are disabled in dev builds. Install Iris from a release DMG to get updates.")
    }

    @Test("no updater is constructed under test")
    func noUpdaterInDev() {
        #expect(UpdaterController.shared == nil)
    }
}
