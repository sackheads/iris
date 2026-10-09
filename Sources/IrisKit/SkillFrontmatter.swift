import Foundation

/// One field of a SKILL.md's YAML frontmatter, read loosely enough for three callers to share:
/// `create_skill`/`update_skill` (`ToolExecutor`), a `write_file` landing on a skill's own
/// `SKILL.md` (`ToolExecutor.writeFile`), and the name/folder mismatch check in
/// `SkillManager.listSkills` (#417). `rawLines` is the field's own "key: value" line plus any
/// indented continuation lines below it (a hand-written multi-line `tags:` list, a folded
/// `description: >` block, say) — kept verbatim rather than semantically parsed, because
/// `update_skill` must round-trip a field it doesn't touch exactly as it found it, line count and
/// all. Nothing here is a YAML parser; it only finds field boundaries by indentation.
struct SkillFrontmatterField: Equatable {
    let key: String
    var rawLines: [String]

    /// The text after the first line's colon, trimmed, with one pair of surrounding YAML quotes
    /// stripped and unescaped if present, or nil for a key with no inline value (a list, or a
    /// folded/literal block scalar, spelled as indented lines below the key rather than
    /// `key: value`). This is a *display* reading only — `render` must never rebuild a field
    /// from this when the field has continuation lines (#417 PR review: a multi-line
    /// `description:` read this way loses every line past the first).
    ///
    /// Unquoting matters because `render`/`yamlScalarLine` quotes a value whenever a bare scalar
    /// would read differently (#417 item 7) — without this, a title like `GKE: nodes`, written
    /// back as `title: "GKE: nodes"`, showed its own quotes verbatim in `/skills` and the
    /// model's skill list (#434 item 1).
    var scalarValue: String? {
        guard let first = rawLines.first, let colon = first.firstIndex(of: ":") else { return nil }
        let raw = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let value = Self.unquoted(raw)
        return value.isEmpty ? nil : value
    }

    /// Strips one pair of surrounding `"..."` or `'...'` quotes from `raw` and unescapes the
    /// content — `\"` and `\\` inside a double-quoted value (the style `SkillFrontmatter.quoted`
    /// writes), `''` inside a single-quoted one. `raw` with no surrounding quotes, or too short
    /// to have a matching pair (a bare `"` on its own), is returned unchanged.
    private static func unquoted(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if raw.hasPrefix("\""), raw.hasSuffix("\"") {
            var result = ""
            var iterator = raw.dropFirst().dropLast().makeIterator()
            while let char = iterator.next() {
                if char == "\\", let escaped = iterator.next() {
                    result.append(escaped)
                } else {
                    result.append(char)
                }
            }
            return result
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'") {
            return raw.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }
}

enum SkillFrontmatter {
    /// The line ending `content` actually uses, so a rewrite can preserve it. CRLF is detected
    /// before any splitting happens — `parse` always normalizes to `\n` internally, and a CRLF
    /// file must get `\r\n` back on the way out or every rewrite skews slightly diffs further
    /// (#417 PR review item 6).
    static func lineEnding(of content: String) -> String {
        content.contains("\r\n") ? "\r\n" : "\n"
    }

    /// Splits `content` into its frontmatter fields (file order preserved) and the Markdown body
    /// below the closing `---`. Content with no `---`-delimited block at the top returns no
    /// fields and the whole text, trimmed, as the body.
    ///
    /// `\r\n` and bare `\r` are normalized to `\n` before splitting. `String.components(separatedBy:
    /// .newlines)` treats `\r` and `\n` as two independent one-character delimiters rather than
    /// recognizing the `\r\n` pair, so a CRLF file split that way produces an extra empty line for
    /// every line break — and rejoining with `\n` later doubles every line break in the file
    /// (#417 PR review item 6). Callers that need the original ending back use `lineEnding(of:)`
    /// on the pre-parse content and re-apply it to the final string they write.
    static func parse(_ content: String) -> (fields: [SkillFrontmatterField], body: String) {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let closeOffset = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
              }) else {
            return ([], normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var fields: [SkillFrontmatterField] = []
        for line in lines[1..<closeOffset] {
            let looksLikeKey = !line.hasPrefix(" ") && !line.hasPrefix("\t") && line.contains(":")
            if looksLikeKey, let colon = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    fields.append(SkillFrontmatterField(key: key, rawLines: [line]))
                    continue
                }
            }
            // A continuation of the previous field (an indented list item, a folded/literal
            // block scalar's wrapped lines, a blank line inside the block). Dropped silently if
            // the block opens with one.
            if !fields.isEmpty {
                fields[fields.count - 1].rawLines.append(line)
            }
        }
        let body = lines[(closeOffset + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (fields, body)
    }

    static func value(_ fields: [SkillFrontmatterField], key: String) -> String? {
        fields.first { $0.key == key }?.scalarValue
    }

    private static func rawLines(_ fields: [SkillFrontmatterField], key: String) -> [String]? {
        fields.first { $0.key == key }?.rawLines
    }

    /// Collapses any newline in a value a caller is about to write inline as `key: value` — never
    /// applied to a carried-over `rawLines` block, which is already safe multi-line YAML. A
    /// `title` or `description` containing `\n` (or `\r`) would otherwise close the frontmatter
    /// block early and spill the rest of its own text, and everything after it, into the skill's
    /// Markdown body (#417 PR review item 2: `title: "Evil\n---\ninjected: yes"`).
    private static func flattenNewlines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// The leading characters that make a bare YAML scalar ambiguous (indicators) or that make it
    /// a different kind of node entirely (`-`, `?`, `:` lead a block sequence/mapping key/value).
    private static let yamlIndicatorChars = Set("-?:,[]{}#&*!|>'\"%@`")

    /// Renders one scalar value as `key: value`, quoting it when a bare scalar would parse
    /// differently or not at all — a value containing `: ` (a second mapping pair), one
    /// containing ` #` (a comment, under strict YAML: `title: Fix C #builds` reads as `Fix C`,
    /// #434 item 2), one starting with a YAML indicator character, one that is empty, or one
    /// with leading/trailing whitespace (#417 PR review item 7: `title: GKE: nodes`). Newlines
    /// are flattened first (never emitted as a bare scalar either way).
    private static func yamlScalarLine(_ key: String, _ rawValue: String) -> String {
        let value = flattenNewlines(rawValue)
        let needsQuoting = value.isEmpty
            || value.first.map { yamlIndicatorChars.contains($0) } == true
            || value.hasSuffix(":")
            || value.contains(": ")
            || value.contains(" #")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuoting else { return "\(key): \(value)" }
        return "\(key): \(quoted(value))"
    }

    /// One double-quoted YAML scalar. Backslashes are escaped *before* quotes: escaping the quote
    /// first on a value ending in `\` (e.g. a tag `back\`) leaves that backslash immediately
    /// before the closing `"`, which escapes the delimiter instead of ending the string
    /// (#417 PR review item 8). Newlines are flattened first, same as any other inline scalar.
    private static func quoted(_ value: String) -> String {
        let flattened = flattenNewlines(value)
        let escaped = flattened.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Builds a fresh OKF frontmatter block for `create_skill`/`update_skill`, in a fixed field
    /// order: `name`, `title`, `description`, `type`, `tags`, `timestamp`, then anything else the
    /// existing file had that none of those cover — preserved verbatim, in its original order.
    ///
    /// `title`/`description`/`type`/`tags` given as `nil` means "say nothing about this field":
    /// the existing file's raw line(s) for it are carried over *unchanged*, line count included,
    /// so `update_skill` never erases or truncates a field a caller didn't ask it to touch
    /// (#417). That matters most for `description`/`type`, which can be a folded (`>`) or literal
    /// (`|`) block scalar, or a plain scalar wrapped onto a continuation line — rendering only
    /// `SkillFrontmatterField.scalarValue` (the first line's text) for either would silently
    /// drop every line after it (#417 PR review, blocking finding).
    ///
    /// `tags` is the one field where `nil` and "given" are told apart by Optional-ness, not
    /// emptiness: a caller that passes `tags: []` *clears* the tags line (emitted as `tags: []`)
    /// rather than leaving the existing one alone (#417 PR review item 9) — `ToolExecutor` is
    /// responsible for keeping that distinction alive from the raw tool-call argument through to
    /// here, since the general-purpose list parsers it uses elsewhere treat an empty list as
    /// "nothing asked".
    ///
    /// `existing` is `[]` for `create_skill`, which never carries anything over.
    static func render(name: String, title: String?, description: String?, type: String?,
                        tags: [String]?, timestamp: String, existing: [SkillFrontmatterField]) -> String {
        var lines: [String] = ["name: \(name)"]
        var used: Set<String> = ["name"]

        if let title {
            lines.append(yamlScalarLine("title", title))
        } else if let raw = rawLines(existing, key: "title") {
            lines.append(contentsOf: raw)
        }
        used.insert("title")

        if let description {
            lines.append(yamlScalarLine("description", description))
        } else if let raw = rawLines(existing, key: "description") {
            lines.append(contentsOf: raw)
        } else {
            lines.append("description: No description provided.")
        }
        used.insert("description")

        if let type {
            lines.append(yamlScalarLine("type", type))
        } else if let raw = rawLines(existing, key: "type") {
            lines.append(contentsOf: raw)
        } else {
            lines.append("type: skill")
        }
        used.insert("type")

        if let tags {
            lines.append("tags: [\(tags.map(quoted).joined(separator: ", "))]")
        } else if let raw = rawLines(existing, key: "tags") {
            lines.append(contentsOf: raw)
        }
        used.insert("tags")

        lines.append("timestamp: \(timestamp)")
        used.insert("timestamp")

        for field in existing where !used.contains(field.key) {
            lines.append(contentsOf: field.rawLines)
        }
        return lines.joined(separator: "\n")
    }

    /// Loose, non-blocking checks for a skill's SKILL.md — never a refusal, because the skill
    /// loader itself doesn't refuse either (#417 item 3: a user skill with a name/folder mismatch
    /// "loads with a warning; it isn't refused"). Shared by `write_file`'s skill-path validation
    /// (item 2) and `SkillManager.listSkills`'s mismatch warning (item 3).
    static func warnings(content: String, folderName: String) -> [String] {
        let (fields, _) = parse(content)
        guard !fields.isEmpty else {
            return ["no YAML frontmatter block (expected to start with '---')"]
        }
        var warnings: [String] = []
        if value(fields, key: "description") == nil {
            warnings.append("no 'description:' field")
        }
        if let explicitName = value(fields, key: "name"), !explicitName.isEmpty,
           explicitName.lowercased() != folderName.lowercased() {
            warnings.append("frontmatter name '\(explicitName)' does not match its folder '\(folderName)'")
        }
        return warnings
    }
}
