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

    /// The composer's full text as of the last `update(text:)`. Kept only to decide whether
    /// Return should accept the highlighted completion or send (#258, `shouldAcceptOnReturn`).
    private(set) var currentText: String = ""

    /// Set by the composer's coordinator; inserts the chosen command into the field.
    var onCommit: ((SlashCommandItem) -> Void)? = nil

    var isShowing: Bool { !suggestions.isEmpty }

    /// Recompute popup state from the composer's full text.
    func update(text: String) {
        currentText = text
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

    /// True when accepting `completion` would still change `text` — i.e. `text` is a strict
    /// prefix of `completion`, not already equal to it (case-insensitively). Once the typed
    /// text equals a complete command there is nothing left to complete (#258): Return should
    /// send it rather than re-insert the same text, while a true prefix (`/jo` of `/jobs`)
    /// still completes as before.
    static func shouldAcceptCompletion(text: String, completion: String) -> Bool {
        let lowerText = text.lowercased()
        let lowerCompletion = completion.lowercased()
        guard lowerText.count < lowerCompletion.count else { return false }
        return lowerCompletion.hasPrefix(lowerText)
    }

    /// Whether pressing Return right now should accept the highlighted suggestion. Consulted
    /// only for the Enter key (#258); Tab and a mouse click on a popup row always commit.
    var shouldAcceptOnReturn: Bool {
        guard suggestions.indices.contains(selectedIndex) else { return false }
        return Self.shouldAcceptCompletion(text: currentText, completion: suggestions[selectedIndex].command)
    }

    /// Insert the highlighted command via `onCommit`, then clear.
    func commitSelected() {
        guard suggestions.indices.contains(selectedIndex) else { return }
        onCommit?(suggestions[selectedIndex])
        clear()
    }
}
