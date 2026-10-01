import Foundation

/// Per-turn content that must not sit in the cached prefix (5a §0.2). Built once per turn,
/// attached to the turn's own user entry in every round's request, never written to history.
struct TurnContext: Equatable, Sendable {
    struct Section: Equatable, Sendable { var heading: String; var body: String }
    var sections: [Section]
    var isEmpty: Bool { sections.isEmpty }

    /// `<turn_context>\n# heading\nbody\n\n# heading\nbody\n</turn_context>`
    func rendered() -> String {
        let body = sections.map { "# \(Self.neutralised($0.heading))\n\(Self.neutralised($0.body))" }
            .joined(separator: "\n\n")
        return "<turn_context>\n\(body)\n</turn_context>"
    }

    /// Section text with every `<` swapped for U+FF1C (fullwidth less-than). Fact text is
    /// model-written, and SYSTEM.md tells the model that text outside the block is the user's, so a
    /// fact holding `</turn_context>` must not be able to end the block early. No `<` means no tag
    /// in any case or spacing. A look-alike rather than `&lt;`: the model reads `a ＜ b` as `a < b`
    /// without decoding anything, and a fact that already contains `&lt;` (code, HTML) stays exact.
    static func neutralised(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "\u{FF1C}")
    }

    /// `contents` with the block inserted as the leading part of `contents[anchor]`, when the
    /// anchor is in range and that entry still encodes to `anchorBytes` (see `anchorBytes(of:)`).
    /// Otherwise `contents` unchanged: a block on the wrong message is worse than none. `Content`
    /// has no identity and is not Equatable; the whole encoded entry is compared, not its first
    /// text, so a *different* entry that shares the first text cannot match. Two entries with
    /// identical parts do encode the same, which is why the anchor index is taken once per list.
    func applied(to contents: [Content], anchor: Int, anchorBytes: Data?) -> [Content] {
        guard !isEmpty, anchorHolds(in: contents, anchor: anchor, anchorBytes: anchorBytes) else { return contents }
        var out = contents
        out[anchor].parts.insert(Part(text: rendered()), at: 0)
        return out
    }

    /// Whether `contents[anchor]` is still the entry `anchorBytes` was taken from.
    func anchorHolds(in contents: [Content], anchor: Int, anchorBytes: Data?) -> Bool {
        guard let anchorBytes, contents.indices.contains(anchor) else { return false }
        return Self.anchorBytes(of: contents[anchor]) == anchorBytes
    }

    /// The bytes an anchor is validated against: sorted keys, so equal entries are equal bytes.
    /// Each `inlineData` is stood in for by its MIME type and encoded length, so a screenshot is
    /// not re-encoded on every round; role, text and every other part still count. The accepted
    /// limit: an entry identical except for an image of the same type and length matches. Getting
    /// one at the anchor mid-turn takes the UI removing the turn's entry and re-adding that.
    static func anchorBytes(of content: Content) -> Data? {
        var stripped = content
        for i in stripped.parts.indices {
            if let image = stripped.parts[i].inlineData {
                stripped.parts[i].inlineData = InlineData(mimeType: image.mimeType, data: "\(image.data.utf8.count)")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(stripped)
    }
}

/// One turn's block and where it goes. A turn sends two lists: round one sends the history the
/// PreCompress hook returned (`.initial`), and every later request re-reads AppState's own list
/// (`.state`), which the hook never touched. Each gets its own anchor, both taken once at the start
/// of the turn; the bytes come from AppState's entry, the one the turn appended.
struct TurnRequest: Sendable {
    enum HistoryList: Sendable { case initial, state }

    let context: TurnContext
    let stateAnchor: Int?
    let initialAnchor: Int?
    let anchorBytes: Data?
    private(set) var dropReported = false

    init(context: TurnContext, stateHistory: [Content], initialHistory: [Content]) {
        self.context = context
        let stateAnchor = stateHistory.lastIndex { $0.role == "user" }
        self.stateAnchor = stateAnchor
        initialAnchor = initialHistory.lastIndex { $0.role == "user" }
        // An empty context sends history as is (`contents(for:from:)`), so it needs no anchor.
        anchorBytes = context.isEmpty ? nil : stateAnchor.flatMap { TurnContext.anchorBytes(of: stateHistory[$0]) }
    }

    /// The request copy of `history`, and whether this is the first call of the turn to find the
    /// anchor broken (so the caller reports it once, not every round).
    mutating func contents(for history: [Content], from list: HistoryList) -> (contents: [Content], firstDrop: Bool) {
        guard !context.isEmpty else { return (history, false) }
        if let anchor = list == .initial ? initialAnchor : stateAnchor,
           context.anchorHolds(in: history, anchor: anchor, anchorBytes: anchorBytes) {
            return (context.applied(to: history, anchor: anchor, anchorBytes: anchorBytes), false)
        }
        defer { dropReported = true }
        return (history, !dropReported)
    }
}
