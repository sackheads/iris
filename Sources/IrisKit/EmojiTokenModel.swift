import Foundation
import Observation

@MainActor
@Observable
final class EmojiTokenModel: PopupNav {
    var activeRange: NSRange? = nil
    var suggestions: [EmojiItem] = []
    var selectedIndex: Int = 0
    var defaultTone: SkinTone = .none

    /// Set by the composer's coordinator; performs the actual text-storage edit.
    var performReplace: ((_ glyph: String, _ range: NSRange) -> Void)? = nil

    let minQueryLength = 2
    private let catalog: EmojiCatalog

    init(catalog: EmojiCatalog = .shared) { self.catalog = catalog }

    var isShowing: Bool { !suggestions.isEmpty }

    /// Recompute popup state from the composer's text + caret.
    func update(text: NSString, caret: Int) {
        guard let token = EmojiTokenizer.activeToken(in: text, caret: caret),
              token.query.count >= minQueryLength else { clear(); return }
        let hits = catalog.matches(prefix: token.query, limit: 8)
        guard !hits.isEmpty else { clear(); return }
        if suggestions.map(\.id) != hits.map(\.id) { selectedIndex = 0 }
        activeRange = token.range
        suggestions = hits
    }

    func clear() {
        activeRange = nil
        suggestions = []
        selectedIndex = 0
    }

    func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
    }

    /// Glyph + range for the highlighted suggestion (does not mutate state).
    func commitSelection() -> (glyph: String, range: NSRange)? {
        guard let range = activeRange, suggestions.indices.contains(selectedIndex) else { return nil }
        let item = suggestions[selectedIndex]
        let glyph = catalog.glyph(for: item.shortcode, tone: defaultTone) ?? item.glyph
        return (glyph, range)
    }

    /// Insert the highlighted suggestion via `performReplace`, then clear.
    func commitSelected() {
        guard let (glyph, range) = commitSelection() else { return }
        performReplace?(glyph, range)
        clear()
    }

    /// The glyph to show in a popup row, honoring the default tone.
    func displayGlyph(for item: EmojiItem) -> String {
        catalog.glyph(for: item.shortcode, tone: defaultTone) ?? item.glyph
    }
}
