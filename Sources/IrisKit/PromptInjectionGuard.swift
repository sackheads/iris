import Foundation

struct PromptInjectionGuard {
    
    /// Tier 1: Text normalization only.
    ///
    /// Normalizes compatibility forms (NFKC) and invisible characters, strips LLM role delimiters,
    /// and returns the cleaned text **unwrapped**. Cross-script homoglyphs are folded only to match a
    /// role word (`roleConfusables`, #1342); the text itself keeps them. Wrapping the content in `<untrusted_context>` (and
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
            stripRecording(normalize(rawInput), patterns: malRolePatterns, bareRoleLines: true)
        }
    }

    /// #1345: a line that is only a role word, a turn header with no colon (`AI`, `**User**`, `system`).
    /// Up to three leading spaces, CommonMark's line between text and code, so `    user` in code is left
    /// alone; optional emphasis and a trailing colon; any case. Not `instruction(s)`, a common doc label.
    /// Best effort, like every text rule here: the canary is the control, not this.
    private static let bareRoleLine = try! NSRegularExpression(
        pattern: #"^ {0,3}(?:\*{1,2}|_{1,2})?(?:system(?: prompt)?|assistant|user|model|human|ai|developer|tool|function):?(?:\*{1,2}|_{1,2})?:?[ \t]*$"#,
        options: [.caseInsensitive])

    /// #1353, measured (the canary passed each 3/3 in #1338's split-05 frame; 0 benign eval rows): a role word in
    /// a code span or with a trailing period, and a `#`/`##` heading of a turn word only. #1361: the forms combine
    /// (`## **User**`, `# User.`, `**User.**`, `` `user`. ``), a code span may be padded or doubled, a heading may close
    /// with `#`s, and `## System Prompt` is a heading too, but only as the whole line. Measured the same way: the
    /// canary judged 10 of the 11 shapes safe 3/3 (#1356: it follows the payload), so for these the strip is the
    /// control. `## Tools` and `## Model` are ordinary README headings, and `[user]` is a real INI section, so
    /// neither is here.
    private static let bareRoleLineForms = try! NSRegularExpression(
        pattern: #"^ {0,3}(?:#{1,2}[ \t]+(?:\*{1,2}|_{1,2})?(?:(?<h>`{1,2}) *(?:system(?: prompt)?|assistant|user|human|ai) *\k<h>|(?:system(?: prompt)?|assistant|user|human|ai))\.?(?:\*{1,2}|_{1,2})?\.?:?(?:[ \t]+#+)?|(?:\*{1,2}|_{1,2})?(?:(?<p>`{1,2}) *(?:system(?: prompt)?|assistant|user|model|human|ai|developer|tool|function) *\k<p>|(?:system(?: prompt)?|assistant|user|model|human|ai|developer|tool|function))\.?(?:\*{1,2}|_{1,2})?\.?:?)[ \t]*$"#,
        options: [.caseInsensitive])

    static func isBareRoleLine(_ line: String) -> Bool {
        matchesFolded(line) { line in
            let whole = NSRange(line.startIndex..., in: line)
            return bareRoleLine.firstMatch(in: line, range: whole) != nil || bareRoleLineForms.firstMatch(in: line, range: whole) != nil
        }
    }

    /// #1342: the Cyrillic and Greek letters Unicode's confusables.txt (18.0.0) gives as a look-alike of a
    /// letter in a role word (a, c, d, e, f, g, h, i, l, m, n, o, p, r, s, t, u, v, y), so `Hуman:` and
    /// `Usеr:` match as `Human:` and `User:`. Only letters NFKC leaves alone, and each a single UTF-16 unit
    /// both ways, so a match in the folded line is the same range in the line itself. Matching only: what
    /// is passed on keeps its own letters. `roleConfusableAlternates` covers the letters it gives a second reading.
    static let roleConfusables: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{03B1}": "a", "\u{0430}": "a", "\u{0391}": "A", "\u{0410}": "A",
        "\u{0441}": "c", "\u{0421}": "C",
        "\u{0501}": "d",
        "\u{0435}": "e", "\u{04BD}": "e", "\u{0395}": "E", "\u{0415}": "E",
        "\u{03DC}": "F",
        "\u{050C}": "G",
        "\u{04BB}": "h", "\u{04BA}": "h", "\u{0397}": "H", "\u{041D}": "H",
        "\u{03B9}": "i", "\u{0456}": "i",
        "\u{0399}": "l", "\u{0406}": "l", "\u{04CF}": "l", "\u{04C0}": "l",
        "\u{039C}": "M", "\u{03FA}": "M", "\u{041C}": "M",
        "\u{039D}": "N",
        "\u{03BF}": "o", "\u{03C3}": "o", "\u{03ED}": "o", "\u{043E}": "o", "\u{039F}": "O", "\u{041E}": "O",
        "\u{03C1}": "p", "\u{03F8}": "p", "\u{0440}": "p", "\u{03A1}": "P", "\u{0420}": "P",
        "\u{0433}": "r",
        "\u{0455}": "s", "\u{0405}": "S",
        "\u{03A4}": "T", "\u{0422}": "T",
        "\u{03C5}": "u",
        "\u{03BD}": "v", "\u{0475}": "v", "\u{0474}": "V",
        "\u{03B3}": "y", "\u{0443}": "y", "\u{04AF}": "y", "\u{03A5}": "Y", "\u{0423}": "Y", "\u{04AE}": "Y",
    ]

    /// Not from confusables.txt, which gives Cyrillic `у` as `y` and capital I's look-alikes as `l` (its
    /// prototype for Latin `I` too). In a role word they read as `u` (`Hуman:`, the case #1342 found) and `I`
    /// (`Іnstruction:`), so a second fold reads them so. No role word has both `y` and `u`, or `I` and `l`.
    static let roleConfusableAlternates: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{0443}": "u", "\u{0399}": "I", "\u{0406}": "I", "\u{04C0}": "I",
    ]
    private static let roleFolds = [roleConfusables, roleConfusables.merging(roleConfusableAlternates) { $1 }]

    /// Whether `text` has a letter either fold changes: the strip's fast path for a line that has none.
    static func hasRoleConfusable(_ text: String) -> Bool {
        text.unicodeScalars.contains { roleFolds[1][$0] != nil }
    }

    static func foldRoleConfusables(_ text: String, alternate: Bool = false) -> String {
        let table = roleFolds[alternate ? 1 : 0]
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.map { table[$0] ?? $0 })
        return String(scalars)
    }

    /// A role-word check that also holds for either folded spelling of the line. Only ever adds a match.
    private static func matchesFolded(_ line: String, _ check: (String) -> Bool) -> Bool {
        if check(line) { return true }
        guard hasRoleConfusable(line) else { return false }
        return [false, true].contains { alternate in
            let folded = foldRoleConfusables(line, alternate: alternate)
            return folded != line && check(folded)
        }
    }

    /// Step 1 alone, for a caller that strips later through `InjectionGuard.sanitizeUntrusted`.
    static func normalize(_ rawInput: String) -> String {
        // 1. Encoding normalization
        // NFKC folds compatibility forms (fullwidth `Ｈｕｍａｎ：` becomes `Human:`), not cross-script
        // look-alikes: a Cyrillic `у` stays one. Those are folded only for role-word matching (#1342).
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
        // #1336: the other half of the `Human:`/`Assistant:` turn format. Not `AI:`, which is no template's role.
        "human:",
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
        matchesFolded(line) { strongDelimiter.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ? 0 : 1
    }

    /// Markdown's own rules and headings, which strip without recording a line.
    private static let markdownOnly: Set<String> = ["---", "###"]
    /// `---`/`###` that do record a line: at its start, before a role word.
    static let delimiterBeforeRole = try! NSRegularExpression(
        pattern: #"^\s*(---|###)\s*(system|assistant|user|model|instruction)\b"#, options: [.caseInsensitive])

    /// The role and chat-template patterns: `malRolePatterns` without the two Markdown-only ones.
    private static let roleOnlyPatterns = malRolePatterns.filter { !markdownOnly.contains($0) }
    /// A standalone run of `---` or `###` (a fence, a rule, a heading marker): bounded by whitespace or the line's ends.
    private static let standaloneStructure = try! NSRegularExpression(pattern: #"(?<!\S)(?:-{3,}|#{3,})(?!\S)"#)

    /// #1275: whether the ONLY thing the strip removed from `normalizedLine` is Markdown structure, so that a
    /// tier-cleared line may be shown as the file has it in the system prompt (`InjectionGuard.FidelityMode
    /// .preserveStructureWhenJudged`). False for a line that carries a role word or chat token, a
    /// delimiter right before a role word (`### System`, with or without a colon), or a `---`/`###` glued to
    /// anything (`IG###NORE`, `sys---tem:`): such a line stays stripped whatever a tier said.
    static func isStructureOnlyMarkerLine(_ normalizedLine: String) -> Bool {
        let whole = NSRange(normalizedLine.startIndex..., in: normalizedLine)
        guard !matchesFolded(normalizedLine, { delimiterBeforeRole.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }),
              !isBareRoleWordLine(normalizedLine) else { return false }
        let remainder = standaloneStructure.stringByReplacingMatches(in: normalizedLine, range: whole, withTemplate: "")
        guard !remainder.contains("---"), !remainder.contains("###") else { return false }
        return stripRecording(remainder, patterns: roleOnlyPatterns).text == remainder
    }

    /// #1329: a line that is only a role word once Markdown and punctuation are set aside (`system`, `### Human`,
    /// `User.`, `role: system`, `System message`, `### Developer`). A turn header split across lines (`---⏎system⏎---`) shows on no single line, so a structure line
    /// next to one of these stays stripped too (`bordersBareRoleWord`).
    private static let bareRoleWord = try! NSRegularExpression(
        pattern: #"^[\s\p{P}\p{S}]*(role\s*[:=]\s*)?(system|assistant|user|model|instructions?|human|ai|developer|tool|function)(\s+(message|prompt|instructions|turn|response))?[\s\p{P}\p{S}]*$"#,
        options: [.caseInsensitive])

    static func isBareRoleWordLine(_ normalizedLine: String) -> Bool {
        matchesFolded(normalizedLine) { bareRoleWord.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }

    /// #1329: a line that is nothing but `---`/`###` runs, the pieces a split turn header is framed with. A heading
    /// with its own text (`### Decisions`) frames nothing, so it is never judged by its neighbours.
    static func isBareStructureLine(_ normalizedLine: String) -> Bool {
        let whole = NSRange(normalizedLine.startIndex..., in: normalizedLine)
        let rest = standaloneStructure.stringByReplacingMatches(in: normalizedLine, range: whole, withTemplate: "")
        return rest.trimmingCharacters(in: .whitespaces).isEmpty && !normalizedLine.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// #1329: whether the nearest non-blank line above or below `index` is a bare role word. Blank lines are
    /// skipped, so `---⏎⏎system` borders it as `---⏎system` does.
    static func bordersBareRoleWord(_ normalizedLines: [String], at index: Int) -> Bool {
        func nearest(_ indices: some Sequence<Int>) -> Bool {
            for i in indices where !normalizedLines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                return isBareRoleWordLine(normalizedLines[i])
            }
            return false
        }
        guard normalizedLines.indices.contains(index) else { return false }
        return nearest(stride(from: index - 1, through: 0, by: -1)) || nearest(index + 1 ..< normalizedLines.count)
    }

    /// A role word's pattern (`system:`, `user:`, `System Prompt:` …) matches only as a whole word
    /// (#736): as a suffix it mangled ordinary keys, `filesystem:` into `file`, in every tool result
    /// the model read. Anywhere in a line, not only at its start, so a mid-line `system:` is still
    /// stripped. The chat-template tokens and `---`/`###` stay plain substrings.
    private static func remove(_ pattern: String, from line: String, foldable: Bool) -> String {
        guard pattern.first?.isLetter == true else {
            return line.replacingOccurrences(of: pattern, with: "", options: [.caseInsensitive])
        }
        let regex = wordRegexes[pattern] ?? wordRegex(pattern)
        let stripped = regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        // #1342: then a role word spelled with a look-alike, matched in the folded line and removed from
        // this one at the same range. Skipped for a line with no table letter. Its boundary adds Cyrillic
        // and Greek letters to the Latin one, so a word of theirs whose ending folds to `model:` is not cut,
        // while `中Usеr:` is stripped as `中User:` is.
        guard foldable else { return stripped }
        let foldedRegex = foldedWordRegexes[pattern] ?? wordRegex(pattern, boundary: foldedBoundary)
        var result = stripped
        for alternate in [false, true] {
            let folded = foldRoleConfusables(result, alternate: alternate)
            guard folded != result else { continue }
            let line = NSMutableString(string: result)
            for match in foldedRegex.matches(in: folded, range: NSRange(folded.startIndex..., in: folded)).reversed() {
                line.deleteCharacters(in: match.range)
            }
            result = line as String
        }
        return result
    }
    private static let latinBoundary = "(?<![A-Za-z0-9_])"
    private static let foldedBoundary = #"(?<![A-Za-z0-9_\p{Script=Cyrillic}\p{Script=Greek}])"#
    private static func wordRegex(_ pattern: String, boundary: String = latinBoundary) -> NSRegularExpression {
        // A lookbehind, not a consumed character: `system:system:` would otherwise keep its second
        // marker, since the first match takes the `:` the second needs before it (#742 review).
        try! NSRegularExpression(pattern: boundary + NSRegularExpression.escapedPattern(for: pattern),
                                 options: [.caseInsensitive])
    }
    /// Built once: `malRolePatterns` covers tier 1's own list too.
    private static let wordRegexes: [String: NSRegularExpression] = Dictionary(
        malRolePatterns.filter { $0.first?.isLetter == true }.map { ($0, wordRegex($0)) },
        uniquingKeysWith: { first, _ in first })
    private static let foldedWordRegexes: [String: NSRegularExpression] = Dictionary(
        malRolePatterns.filter { $0.first?.isLetter == true }.map { ($0, wordRegex($0, boundary: foldedBoundary)) },
        uniquingKeysWith: { first, _ in first })

    /// #970: a single pass over the pattern list can REASSEMBLE a marker it was supposed to
    /// remove. `model:` is checked before `---` in `malRolePatterns`' order, so `mo---del:` finds
    /// no `model:` on the `model:` step, then the `---` step joins the fragments into a live
    /// `model:` — which nothing in that same pass checks again. The same happens across any two
    /// patterns where an earlier-order pattern's removal exposes a later/already-passed one
    /// (`<|im_<|im_end|>start|>` → removing `<|im_end|>` exposes `<|im_start|>`). Fixing it with
    /// a fixed-point loop (repeat until a pass changes nothing) is not itself enough: a single
    /// pattern (or a pair of patterns) whose removal exposes another occurrence that nothing
    /// later in the SAME pass re-checks lets an attacker nest arbitrarily deep — each layer costs
    /// exactly one more pass to unwind — so a cap on pass count alone would hit the cap mid-unwind
    /// and return a partial strip that can still carry a live marker (#972 review). This is not
    /// limited to chat-template tokens: `---`/`###` alone can't self-nest (two fragments of the
    /// *same* character just merge into one homogeneous run that a single `replacingOccurrences`
    /// call resolves fully), but ALTERNATING `---` and `###` wrappers around each other can (dev-2
    /// review round 2) — any pattern pair whose removals expose each other across a pass boundary
    /// is a nesting risk, not only self-nesting ones. So hitting the cap without a pass that
    /// changes nothing is treated as non-termination and fails closed to a fixed placeholder
    /// (`nestedDelimiterPlaceholder`), never the partial text: no legitimate input nests this
    /// deep, so the placeholder costs nothing, and the cap now only bounds CPU (a 1 MB line
    /// nested 100k deep would otherwise cost passes × length), which is what it's for. The
    /// fail-closed branch below covers every pattern and pattern-pair uniformly, since the cap
    /// itself is pattern-agnostic.
    private static let maxStripPasses = 20
    /// Replaces a line whose strip never reached a fixed point within `maxStripPasses` (#972
    /// review) — an attacker-chosen nesting depth beyond anything a legitimate input needs.
    static let nestedDelimiterPlaceholder = "[line withheld: nested delimiters]"

    /// Strips `patterns` line by line, in order, repeating the full pattern-list pass until a
    /// whole pass makes no further change (fixed point, #970) or `maxStripPasses` is hit — in
    /// which case the line fails closed to `nestedDelimiterPlaceholder` rather than return a
    /// partial strip that could still carry a live marker (#972 review) — exactly as a
    /// whole-text replace would (none spans a newline), and records each line a delimiter was
    /// stripped from, including one revealed only by a later pass's reassembly, or withheld
    /// outright for failing to converge.
    /// `bareRoleLines` (#1345): also empty a line that is, or after the strip is, only a role word
    /// (`isBareRoleLine`), recording it. The untrusted pre-strip asks for it; tier 1's own list does not.
    static func stripRecording(_ text: String, patterns: [String], bareRoleLines: Bool = false) -> (text: String, delimiterLines: [Int: String]) {
        var recorded: [Int: String] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, raw -> String in
            let original = String(raw)
            var line = original
            // Stripping only removes characters, so a line with no table letter never gains one.
            let foldable = hasRoleConfusable(original)
            var counts = false
            var reachedFixedPoint = false
            for _ in 0..<maxStripPasses {
                var changedThisPass = false
                for pattern in patterns {
                    let stripped = remove(pattern, from: line, foldable: foldable)
                    if stripped != line {
                        changedThisPass = true
                        if !markdownOnly.contains(pattern) { counts = true }
                    }
                    line = stripped
                }
                if !changedThisPass { reachedFixedPoint = true; break }
            }
            if !reachedFixedPoint {
                recorded[index] = original
                return nestedDelimiterPlaceholder
            }
            if !counts, line != original,
               matchesFolded(original, { delimiterBeforeRole.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) {
                counts = true
            }
            // After the strip too: `<|im_start|>assistant` leaves a bare `assistant`.
            if bareRoleLines, isBareRoleLine(original) || isBareRoleLine(line) {
                recorded[index] = original
                return ""
            }
            if counts { recorded[index] = original }
            return line
        }
        return (lines.joined(separator: "\n"), recorded)
    }
}
