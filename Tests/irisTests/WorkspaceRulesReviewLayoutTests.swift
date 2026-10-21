import Testing
import AppKit
import SwiftUI
@testable import IrisKit

/// #631: the Review Workspace Rules sheet must fit the room a sheet gets when the window is at its
/// 400 pt minimum (about 310 pt), with a long workspace path and the "changed since you opened
/// this" line, so its buttons are never cut off. Measured with the real view, off screen.
@MainActor
@Suite("Review Workspace Rules fits a short window (#631)")
struct WorkspaceRulesReviewLayoutTests {
    private func review(changed: Bool) -> WorkspaceRulesReview {
        let longPath = "/Users/someone/Projects/" + String(repeating: "a-rather-long-folder-name/", count: 6) + "workspace"
        let files = [(file: "permissions.json", data: Data(String(repeating: "{\"allow\": \"run_command:make\"}\n", count: 40).utf8))]
        return WorkspaceRulesReview(files: files, workspace: longPath, changedWhileOpen: changed, trust: { _ in }, dismiss: {})
    }

    @Test("at the room a 400 pt window leaves, the sheet asks for no more than it's given")
    func fitsTheMinimumWindow() {
        let room: CGFloat = 310
        for changed in [false, true] {
            let size = NSHostingController(rootView: review(changed: changed)).sizeThatFits(in: CGSize(width: 600, height: room))
            #expect(size.height <= room, "changed: \(changed), wants \(size.height) pt of \(room)")
        }
    }

    @Test("with room to spare it still shows the text and a useful stretch of the files")
    func usesRoomWhenThereIsSome() {
        let size = NSHostingController(rootView: review(changed: true)).sizeThatFits(in: CGSize(width: 600, height: 2_000))
        #expect(size.height >= 400, "\(size.height)")
    }
}
