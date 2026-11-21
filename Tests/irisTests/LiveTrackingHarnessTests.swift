import Testing
import SwiftUI
@testable import IrisKit

@Observable @MainActor final class LiveBox { var text = "AAAA" }

/// Reads the box inside `body`: the shape #988 restored.
private struct LiveReadView: View {
    var box: LiveBox
    var body: some View { Text(box.text).font(.system(size: 40, weight: .heavy)) }
}

/// Takes the value as a captured parameter: the shape of #223/#224.
private struct CapturedValueView: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 40, weight: .heavy)) }
}

@MainActor
@Suite("Live-tracking harness (#1277)", .serialized, .timeLimit(.minutes(1)))
struct LiveTrackingHarnessTests {
    @Test("a view that reads observable state in body repaints when it changes")
    func liveReadRepaints() {
        let box = LiveBox()
        let host = ViewHost { LiveReadView(box: box) }
        #expect(host.repaints { box.text = "BBBB" })
    }

    @Test("control: a view that captured the value does not repaint, so the harness can see a freeze")
    func capturedValueFreezes() {
        let box = LiveBox()
        let host = ViewHost { CapturedValueView(text: box.text) }
        #expect(!host.repaints(within: 0.3) { box.text = "BBBB" })
    }

    @Test("an unchanged value does not repaint")
    func noChangeNoRepaint() {
        let box = LiveBox()
        let host = ViewHost { LiveReadView(box: box) }
        #expect(!host.repaints(within: 0.3) { })
    }
}

/// The first consumer: the row #988 had to keep reading live. Its elapsed clock ticks once a
/// second, so the digest covers the left part (glyph, role, activity text) only.
@MainActor
@Suite("ActivityRowView re-renders when its run changes (#1277, #988)", .serialized, .timeLimit(.minutes(1)))
struct ActivityRowLiveTrackingTests {
    private static let left = CGRect(x: 0, y: 0, width: 0.5, height: 1)

    private func app() -> AppState {
        AppState(store: try! ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
    }

    @Test("a subagent row repaints when its phase changes")
    func phaseRepaints() {
        let a = app(), id = UUID()
        a.registerSubagent(id: id, role: "engineer")
        let host = ViewHost(size: CGSize(width: 520, height: 30), region: Self.left) {
            ActivityRowView(state: a, sessionId: id, isMain: false, onTap: {})
        }
        #expect(host.repaints { a.updateRunPhase(id, .executing(tool: "run_command", detail: "swift build")) })
    }

    @Test("control: a change to a run the row is not showing does not repaint it")
    func otherRunDoesNotRepaint() {
        let a = app(), id = UUID(), other = UUID()
        a.registerSubagent(id: id, role: "engineer")
        a.registerSubagent(id: other, role: "reviewer")
        let host = ViewHost(size: CGSize(width: 520, height: 30), region: Self.left) {
            ActivityRowView(state: a, sessionId: id, isMain: false, onTap: {})
        }
        #expect(!host.repaints(within: 0.3) { a.updateRunPhase(other, .executing(tool: "run_command", detail: "x")) })
    }
}
