import SwiftUI

/// The app's SwiftUI transitions under Reduce Motion (#562). Apple's guidance: replace motion with
/// a dissolve or with nothing. So, with Reduce Motion on, a slide-in becomes a dissolve in place,
/// and an expand/collapse or a spring becomes instant (a height change cannot be dissolved without
/// motion). With it off, everything is as it was.
///
/// The setting comes from #538's `ReduceMotion` provider, not SwiftUI's read-only
/// `accessibilityReduceMotion`, so a test can set it. These are read when a transition happens (a
/// button's action, a body re-evaluated for the change), so they follow the setting without
/// observing it. Every `withAnimation`, `.animation(_:value:)` and `.transition(_:)` in the app
/// goes through here; `MotionTests` fails on a new one that does not.
@MainActor
enum Motion {
    /// `base`, or no animation under Reduce Motion.
    static func animation(_ base: Animation?, _ reduceMotion: ReduceMotion = .system) -> Animation? {
        reduceMotion.isOn ? nil : base
    }

    /// A view sliding in from the bottom as it fades, or only the fade under Reduce Motion.
    static func slide(_ reduceMotion: ReduceMotion = .system) -> AnyTransition {
        slides(reduceMotion) ? .move(edge: .bottom).combined(with: .opacity) : .opacity
    }

    /// Whether `slide` moves the view, or only fades it: the rule, apart from `AnyTransition`, which
    /// cannot be compared.
    static func slides(_ reduceMotion: ReduceMotion = .system) -> Bool { !reduceMotion.isOn }

    /// SwiftUI's `withAnimation`, with `animation(_:_:)`'s rule.
    static func withAnimation<Result>(_ base: Animation? = .default, _ reduceMotion: ReduceMotion = .system,
                                      _ body: () throws -> Result) rethrows -> Result {
        try SwiftUI.withAnimation(animation(base, reduceMotion), body)
    }
}
