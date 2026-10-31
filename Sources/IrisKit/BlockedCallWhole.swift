import Foundation

/// A blocked call as "Approve and run" will dispatch it, read from the ledger (#834). A card keeps
/// a cut copy (`EventCard.displayCopy`) so the transcript stays small; this is the whole one, for
/// a sheet that shows what the click writes before the click.
struct BlockedCallWhole: Equatable, Sendable {
    struct Field: Identifiable, Equatable, Sendable {
        var id: String { key }
        let key: String
        let text: String
        /// "12,345 characters, 310 lines, 12.9 KB": how much is there, for a person deciding
        /// whether to read it all. Only a content-like field gets one; a path or command is short.
        let size: String?
    }

    static let writingTools: Set<String> = ["write_file"]

    let toolName: String
    /// Where a file write lands: the call's `path` resolved against its working directory the way
    /// the executor does, then through any symlink (as a held write's target is, #828), so a link's
    /// spelling is not shown as the file. nil for a tool that does not write a file.
    let target: String?
    let fields: [Field]

    init(call: BlockedCall) {
        toolName = call.toolName
        if Self.writingTools.contains(call.toolName), let path = call.args["path"] {
            target = IrisPaths.realPath(ToolExecutor.resolvePath(path.stringValue, cwd: call.cwd))
        } else {
            target = nil
        }
        fields = call.args.keys.sorted().map { key in
            let text = EventCard.renderedText(call.args[key] ?? .null)
            let sized = !EventCard.executionBearingArguments.contains(key)
            return Field(key: key, text: text, size: sized ? Self.sizeLine(text) : nil)
        }
    }

    /// One line a sheet can show above a body.
    static func sizeLine(_ text: String) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
        let characters = text.count.formatted()
        let lineCount = EventCard.lines(of: text).count
        return "\(characters) \(text.count == 1 ? "character" : "characters"), "
            + "\(lineCount.formatted()) \(lineCount == 1 ? "line" : "lines"), \(bytes)"
    }
}

extension EventCard {
    /// Whether the card's copy of the call has a content-like argument cut by `preview`, read from
    /// the note `preview` leaves at the end of the text it cut. An execution-bearing argument or an
    /// outbound call's is never cut. A body that ends in such a note by itself is a harmless false
    /// positive: the sheet shows the same text.
    var hasCutArguments: Bool {
        guard let blockedCall, !showsArgumentsWhole else { return false }
        return blockedCall.args.contains { key, value in
            !Self.executionBearingArguments.contains(key)
                && Self.endsWithCutNote(Self.renderedText(value))
        }
    }

    static func endsWithCutNote(_ text: String) -> Bool {
        guard text.hasSuffix(")"), let open = text.range(of: "… (", options: .backwards) else { return false }
        let note = text[open.upperBound...].dropLast()
        return note.hasSuffix("characters") || note.hasSuffix("more line") || note.hasSuffix("more lines")
    }
}
