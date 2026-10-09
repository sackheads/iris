import Foundation

/// One field of a SKILL.md's YAML frontmatter, read loosely enough for three callers to share:
/// `create_skill`/`update_skill` (`ToolExecutor`), a `write_file` landing on a skill's own
/// `SKILL.md` (`ToolExecutor.writeFile`), and the name/folder mismatch check in
/// `SkillManager.listSkills` (#417). `rawLines` is the field's own "key: value" line plus any
/// indented continuation lines below it (a hand-written multi-line `tags:` list, say) — kept
/// verbatim rather than semantically parsed, because `update_skill` must round-trip a field it
/// doesn't touch exactly as it found it. Nothing here is a YAML parser; it only finds field
/// boundaries by indentation.
struct SkillFrontmatterField: Equatable {
    let key: String
    var rawLines: [String]

    /// The text after the first line's colon, trimmed, or nil for a key with no inline value
    /// (a list spelled as indented lines below the key rather than `key: value`).
    var scalarValue: String? {
        guard let first = rawLines.first, let colon = first.firstIndex(of: ":") else { return nil }
        let value = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

enum SkillFrontmatter {
    /// Splits `content` into its frontmatter fields (file order preserved) and the Markdown body
    /// below the closing `---`. Content with no `---`-delimited block at the top returns no
    /// fields and the whole text, trimmed, as the body.
    static func parse(_ content: String) -> (fields: [SkillFrontmatterField], body: String) {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let closeOffset = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
              }) else {
            return ([], content.trimmingCharacters(in: .whitespacesAndNewlines))
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
            // A continuation of the previous field (an indented list item, a wrapped value, a
            // blank line inside the block). Dropped silently if the block opens with one.
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

    /// One tag, quoted for a YAML flow list. Tags are short kebab-case words in practice; a
    /// literal `"` is escaped rather than refused, since nothing upstream validates tag content.
    private static func quoted(_ tag: String) -> String {
        "\"\(tag.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// Builds a fresh OKF frontmatter block for `create_skill`/`update_skill`, in a fixed field
    /// order: `name`, `title`, `description`, `type`, `tags`, `timestamp`, then anything else the
    /// existing file had that none of those cover — preserved verbatim, in its original order.
    ///
    /// `title`/`tags` given as `nil` means "say nothing about this field": the existing file's
    /// raw line(s) for it are carried over unchanged, so `update_skill` never erases a `title` or
    /// `tags` block a caller didn't ask it to touch (#417). An existing file is `[]` for
    /// `create_skill`, which never carries anything over.
    static func render(name: String, title: String?, description: String, type: String,
                        tags: [String]?, timestamp: String, existing: [SkillFrontmatterField]) -> String {
        var lines: [String] = ["name: \(name)"]
        var used: Set<String> = ["name"]

        if let title {
            lines.append("title: \(title)")
        } else if let raw = rawLines(existing, key: "title") {
            lines.append(contentsOf: raw)
        }
        used.insert("title")

        lines.append("description: \(description)")
        used.insert("description")

        lines.append("type: \(type)")
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
