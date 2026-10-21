import Foundation

struct PromptInjectionGuard {
    
    /// Tier 1: Text normalization only.
    ///
    /// Normalizes homoglyphs/encodings and strips LLM role delimiters, and returns the
    /// cleaned text **unwrapped**. Wrapping the content in `<untrusted_context>` (and
    /// escaping any breakout closing tags) is the responsibility of `InjectionGuard.sanitize`,
    /// which owns the final encapsulation. This ordering is deliberate: the Tier 2/Tier 3
    /// classifiers in `InjectionGuard` must evaluate the *content*, not the XML scaffolding —
    /// a prompt-injection classifier reads `<untrusted_context>` wrapping as an injection and
    /// flags essentially all benign tool output (see docs/prompt_guard_coreml.md and the
    /// "Guardrail Diagnostics" regression).
    static func sanitizeUntrustedInput(_ rawInput: String) -> String {
        stripRecordingDelimiters(rawInput).text
    }

    /// `sanitizeUntrustedInput`'s text, plus the lines a role delimiter was stripped from (#727),
    /// keyed by 0-based line and holding that line as it read before the strip (normalized), which
    /// tier 2 scores alone. Line-preserving: nothing here removes a newline, so line N of the
    /// result is line N of the input. `---` and `###` alone don't record a line (every Markdown
    /// document has them); at a line's start before a role word they do.
    static func stripRecordingDelimiters(_ rawInput: String) -> (text: String, delimiterLines: [Int: String]) {
        measureSync(.injectionGuard) {
            stripRecording(normalize(rawInput), patterns: malRolePatterns)
        }
    }

    /// Step 1 alone, for a caller that strips later through `InjectionGuard.sanitizeUntrusted`.
    static func normalize(_ rawInput: String) -> String {
        // 1. Homoglyph & Encoding Normalization
        // Normalize to prevent attackers from using invisible characters or weird encodings to bypass filters.
        // We use NFKC to normalize compatibility characters.
        var clean = rawInput.precomposedStringWithCompatibilityMapping

        // Remove control characters (except common whitespace like newlines/tabs). Foundation's
        // `whitespacesAndNewlines` also classifies U+200B (ZERO WIDTH SPACE) as whitespace, so a
        // straight subtraction lets it survive — and it is the classic vector for splitting a
        // trigger word (`ig\u{200B}nore`) past a classifier or pattern check while the model
        // still reads the word (#241). Strip it explicitly. The audit of the other invisible Cf
        // characters (U+200C/U+200D/U+2060/U+200E/U+200F/U+FEFF/U+00AD and the bidi controls)
        // found `controlCharacters` already covers them — they are not whitespace — so only
        // U+200B needs the extra entry.
        let controlChars = CharacterSet.controlCharacters
            .subtracting(CharacterSet.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "\u{200B}"))
        clean = clean.components(separatedBy: controlChars).joined()
        return clean
    }

    // 2. Strip common LLM role delimiters that attempt to hijack the conversation
    static let malRolePatterns = [
        "system:",
        "assistant:",
        "user:",
        "model:",
        "---",
        "###",
        "<|im_start|>",
        "<|im_end|>",
        "Instruction:",
        "System Prompt:"
    ]

    /// Delimiters that open a chat turn of the model's or the system's own: the strongest signal.
    /// The role words count only as whole words (#735 review): `subsystem:` and `data_model:` are
    /// ordinary keys, and 64 of them would otherwise fill the strong class ahead of a real `system:`.
    private static let strongDelimiter = try! NSRegularExpression(
        pattern: #"<\|im_(start|end)\|>|(^|[^A-Za-z0-9_])(system|assistant|model|system prompt):"#,
        options: [.caseInsensitive])

    /// 0 for a line carrying a chat-template token or a system/assistant/model delimiter, 1 for
    /// one with only `user:`, `Instruction:` or a Markdown marker before a role word. Tier 2 spends
    /// its cap on the strong ones first (planner, #735), so 64 padding `user:` lines can't push a
    /// `system:` line past it.
    static func delimiterStrength(_ line: String) -> Int {
        strongDelimiter.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil ? 0 : 1
    }

    /// Markdown's own rules and headings, which strip without recording a line.
    private static let markdownOnly: Set<String> = ["---", "###"]
    /// `---`/`###` that do record a line: at its start, before a role word.
    private static let delimiterBeforeRole = try! NSRegularExpression(
        pattern: #"^\s*(---|###)\s*(system|assistant|user|model|instruction)\b"#, options: [.caseInsensitive])

    /// A role word's pattern (`system:`, `user:`, `System Prompt:` …) matches only as a whole word
    /// (#736): as a suffix it mangled ordinary keys, `filesystem:` into `file`, in every tool result
    /// the model read. Anywhere in a line, not only at its start, so a mid-line `system:` is still
    /// stripped. The chat-template tokens and `---`/`###` stay plain substrings.
    private static func remove(_ pattern: String, from line: String) -> String {
        guard pattern.first?.isLetter == true else {
            return line.replacingOccurrences(of: pattern, with: "", options: [.caseInsensitive])
        }
        let regex = wordRegexes[pattern] ?? wordRegex(pattern)
        return regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1")
    }
    private static func wordRegex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: "(^|[^A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: pattern),
                                 options: [.caseInsensitive])
    }
    /// Built once: `malRolePatterns` covers tier 1's own list too.
    private static let wordRegexes: [String: NSRegularExpression] = Dictionary(
        malRolePatterns.filter { $0.first?.isLetter == true }.map { ($0, wordRegex($0)) },
        uniquingKeysWith: { first, _ in first })

    /// Strips `patterns` line by line, in order, exactly as a whole-text replace would (none spans
    /// a newline), and records each line a delimiter was stripped from.
    static func stripRecording(_ text: String, patterns: [String]) -> (text: String, delimiterLines: [Int: String]) {
        var recorded: [Int: String] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, raw -> String in
            let original = String(raw)
            var line = original
            var counts = false
            for pattern in patterns {
                let stripped = remove(pattern, from: line)
                if stripped != line, !markdownOnly.contains(pattern) { counts = true }
                line = stripped
            }
            if !counts, line != original,
               delimiterBeforeRole.firstMatch(in: original, range: NSRange(original.startIndex..., in: original)) != nil {
                counts = true
            }
            if counts { recorded[index] = original }
            return line
        }
        return (lines.joined(separator: "\n"), recorded)
    }
}
