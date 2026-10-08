import Foundation
import Observation

/// Shared surface for a composer popup that the NSTextView routes arrow/Tab/Enter/Esc
/// keys into. The emoji and slash-command popups both conform; they are mutually
/// exclusive by construction (slash matches only at string start, emoji only inside a
/// `:` token), so the composer routes a keystroke to whichever one is showing.
@MainActor
protocol PopupNav: AnyObject {
    var isShowing: Bool { get }
    func moveSelection(_ delta: Int)
    func commitSelected()
    func clear()
}

@MainActor
@Observable
final class SlashCommandModel: PopupNav {
    var suggestions: [SlashCommandItem] = []
    var selectedIndex: Int = 0

    /// Set by the composer's coordinator; inserts the chosen command into the field.
    var onCommit: ((SlashCommandItem) -> Void)? = nil

    var isShowing: Bool { !suggestions.isEmpty }

    /// Recompute popup state from the composer's full text.
    func update(text: String) {
        let hits = SlashCommandItem.matches(for: text)
        guard !hits.isEmpty else { clear(); return }
        if suggestions.map(\.id) != hits.map(\.id) { selectedIndex = 0 }
        suggestions = hits
    }

    func clear() {
        suggestions = []
        selectedIndex = 0
    }

    func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
    }

    /// Insert the highlighted command via `onCommit`, then clear.
    func commitSelected() {
        guard suggestions.indices.contains(selectedIndex) else { return }
        onCommit?(suggestions[selectedIndex])
        clear()
    }
}
