import SwiftUI

/// The sidebar row's "needs you" mark (#466): a trailing 7 pt red pip, the owner's pick. The look
/// lives here alone, so changing it is a one-file change. Static, so Reduce Motion has nothing to change (#538), and drawn from a system
/// colour, which brings its own light and dark variants.
struct NeedsHumanMark: ViewModifier {
    /// What the row is waiting on, or nil for no mark.
    let reason: String?
    /// `.increased` on a selected row, whose accent fill would swallow a red dot.
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Self.Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            content
            if let reason {
                Spacer(minLength: 0)
                Circle()
                    .fill(prominence == .increased ? Color.white : Color(nsColor: .systemRed))
                    .frame(width: 7, height: 7)
                    .help("Needs you: \(reason)")
                    .accessibilityLabel("Needs you: \(reason)")
            }
        }
    }
}

extension View {
    /// Marks a conversation row that is waiting on the person (#466).
    func needsHumanMark(_ reason: String?) -> some View { modifier(NeedsHumanMark(reason: reason)) }
}
