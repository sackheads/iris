import AppKit
import SwiftUI
import Testing
@testable import IrisKit

/// #672: the status LED bar steps up to a large size on a wide pane, and its row stays one of a
/// few fixed heights (the composer stack's rows must stay bounded, Invariant 8).
@MainActor
@Suite("LED bar sizes (#672)")
struct LEDBarSizeTests {
    private func measured(width: CGFloat) -> CGSize {
        let name = "iris-ledsize-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let host = NSHostingController(rootView: ModelLEDBar(config: ConfigManager(store: store)))
        return host.sizeThatFits(in: CGSize(width: width, height: 1_000))
    }

    @Test("a narrow pane gets the regular bar, a wide one the large bar; both rows are bounded")
    func steps() {
        let narrow = measured(width: 400)       // about the detail pane at the window's minimum
        let wide = measured(width: 1_200)
        #expect(narrow.width <= 400, "the regular bar fits the narrowest pane: \(narrow)")
        #expect(wide.width >= LEDBarSize.largeFromWidth, "a wide pane gets the large bar: \(wide)")
        #expect(wide.height > narrow.height, "the large bar is taller: \(narrow) \(wide)")
        #expect(wide.height <= narrow.height * LEDBarSize.large.scale + 2, "and only by its scale: \(narrow) \(wide)")
        #expect(narrow.height < 40 && wide.height < 40, "neither takes the height it's offered: \(narrow) \(wide)")
        #expect(measured(width: LEDBarSize.largeFromWidth - 1).height == narrow.height, "the step is at largeFromWidth")
    }

    @Test("the dot's path, bounds and glow follow its side")
    func dotFollowsSide() throws {
        let dot = LEDDotNSView(state: .ready, reduceMotion: MotionSwitch(false).motion, side: 12.5)
        dot.layout()
        #expect(dot.dot.bounds.width == 12.5)
        #expect(try #require(dot.dot.path).boundingBox.width == 12.5)
        let regular = LEDDotNSView(state: .ready, reduceMotion: MotionSwitch(false).motion)
        #expect(dot.dot.shadowRadius == regular.dot.shadowRadius * 1.25, "the glow grows with it")
        dot.side = LEDDotView.side
        dot.layout()
        #expect(try #require(dot.dot.path).boundingBox.width == LEDDotView.side, "a changed side redraws it")
        #expect(dot.dot.shadowRadius == regular.dot.shadowRadius)
    }
}
