import SwiftUI
import AppKit

/// The main window's chat scrolls under the titlebar and toolbar. With no backing set, the system
/// material blurs the transcript through the bar, which reads as ghost text behind the title (#1058).
/// A solid backing keeps the bar's contents readable; the stored title and the transcript are untouched.
extension View {
    func solidTitlebarBacking() -> some View {
        self
            .toolbarBackground(Color(NSColor.windowBackgroundColor), for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
    }

    /// macOS 26 adds a soft blur where a scroll view meets the bar; `.hard` ends the transcript at
    /// the bar's edge instead. Earlier systems have no such effect.
    @ViewBuilder
    func hardTopScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}
