import Foundation

/// Per-turn content that must not sit in the cached prefix (5a §0.2). Built once per turn,
/// attached to the turn's own user entry in every round's request, never written to history.
struct TurnContext: Equatable, Sendable {
    struct Section: Equatable, Sendable { var heading: String; var body: String }
    var sections: [Section]
    var isEmpty: Bool { sections.isEmpty }

    /// `<turn_context>\n# heading\nbody\n\n# heading\nbody\n</turn_context>`
    func rendered() -> String {
        let body = sections.map { "# \($0.heading)\n\($0.body)" }.joined(separator: "\n\n")
        return "<turn_context>\n\(body)\n</turn_context>"
    }

    /// `contents` with the block inserted as the leading part of `contents[anchor]`, when the
    /// anchor is in range and that entry still encodes to `anchorBytes` (sorted-key JSON of the
    /// exact `Content` the turn appended). Otherwise `contents` unchanged: a block on the wrong
    /// message is worse than none. `Content` has no identity and is not Equatable; the whole
    /// encoded entry is compared, not its first text, so a repeated "yes" cannot match.
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
    static func anchorBytes(of content: Content) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(content)
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
        anchorBytes = stateAnchor.flatMap { TurnContext.anchorBytes(of: stateHistory[$0]) }
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
