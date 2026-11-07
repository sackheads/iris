import Foundation

/// #912: an allow-list sanitizer on the phase-1 raw-HTML render path, closing the viewer's
/// dns-prefetch gap by construction (docs/specs/2026-11-02-webkit-viewer.md section 1). #904
/// found the SOCKS5h proxy can prove `rel=preconnect` reaches zero but cannot observe
/// `rel=dns-prefetch`/`rel=prefetch` at all — Brian's call (2026-11-07) was to close the whole
/// class by stripping it before the document is ever shown, rather than by observation. This is
/// independent of phase 2's SVG/Mermaid sanitizer (spec section 3): that one runs on markup a
/// bundled renderer returns, this one runs on the model's own raw HTML, and phase 2 has not been
/// built yet.
///
/// A real tokenizer, not a regex deny-list: `rel` is multi-token (`rel="stylesheet dns-prefetch"`),
/// so a substring/regex pass over the whole document either over- or under-matches it. This walks
/// the byte stream once, classifying `<tag ...>` / `</tag>` / text / comment, and rebuilds the
/// tag's own attribute list token by token — it is not a DOM (no tree, no nesting rules), which
/// is enough for an allow-list over tags and attributes with no tag needing to know its parent.
enum RawHTMLSanitizer {
    /// Tags dropped along with everything between their open and close tag: no amount of
    /// attribute filtering makes these safe to keep, and (`script` aside, already inert under the
    /// CSP) their content is never meant to render as text either.
    /// `base` is deliberately absent: it is a void element with no closing tag in real markup,
    /// so treating it as a content-dropping container (pushing it onto `skipDepth`) swallowed
    /// everything after it up to end-of-document waiting for a `</base>` that never comes (caught
    /// by `mixedDocumentFixture`). It is excluded from `allowedTags` instead, which drops the
    /// tag itself with no content to keep — a void element has none.
    private static let dropWithContent: Set<String> = [
        "script", "style", "iframe", "object", "embed", "frame", "frameset", "applet", "title",
    ]

    /// Every other disallowed tag is dropped but its text content is kept (an unknown or
    /// deliberately-excluded wrapper around ordinary text should not delete the text).
    private static let allowedTags: Set<String> = [
        "html", "head", "body",
        "div", "span", "p", "br", "hr",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "dl", "dt", "dd",
        "table", "caption", "colgroup", "col", "thead", "tbody", "tfoot", "tr", "td", "th",
        "a", "img", "picture", "source", "figure", "figcaption",
        "b", "i", "u", "s", "strong", "em", "small", "sub", "sup", "mark", "abbr", "cite", "q",
        "time", "code", "kbd", "samp", "pre", "blockquote",
        "address", "article", "section", "nav", "header", "footer", "aside", "main",
        "details", "summary",
        "form", "label", "input", "button", "select", "option", "textarea", "fieldset", "legend",
        "link", "meta",
        // Inline SVG (spec section 3: "Raw HTML and CSS, with inline SVG"). Excludes the same
        // elements phase 2's own SVG allow-list excludes (spec section 3): `foreignObject`,
        // `use`, `animate`, `set` (they can set `href`), and `script`/`style` are already in
        // `dropWithContent` above.
        "svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
        "text", "tspan", "defs", "symbol",
    ]

    /// `rel` tokens that trigger a speculative load: #904's finding was that WebKit resolves
    /// these (or may) without any other channel seeing it. Stripped as a class, not by the five
    /// names the spec happens to list — `dns-prefetch`/`preconnect`/`prerender`/`prefetch`/
    /// `preload`/`modulepreload` today, and any future rel WebKit treats the same way is caught
    /// by extending this set, not by re-deriving the strip logic.
    private static let speculativeRelTokens: Set<String> = [
        "dns-prefetch", "preconnect", "prerender", "prefetch", "preload", "modulepreload",
    ]

    /// Attributes allowed on any element, before each tag's own rules (below) narrow further.
    private static let globalAttributeAllowlist: Set<String> = [
        "id", "class", "style", "title", "alt", "width", "height", "colspan", "rowspan",
        "align", "valign", "dir", "lang",
    ]

    /// Per-tag attributes on top of the global allow-list. A tag not listed here gets only the
    /// global set. `href`/`ping`/`action`/`http-equiv`/`src` are handled by name below, never
    /// just allow-listed, because their *values* need inspecting, not just their names.
    private static let perTagAttributeAllowlist: [String: Set<String>] = [
        "img": ["src"],
        "source": ["src", "srcset", "type"],
        "a": [],   // href and ping are handled explicitly; nothing else is tag-specific
        "link": ["rel", "href", "type"],
        "meta": ["charset", "name", "content"],
        "form": [],   // action is handled explicitly
        "input": ["type", "name", "value", "placeholder", "disabled", "checked"],
        "button": ["type", "disabled"],
        "select": ["name", "disabled"],
        "option": ["value", "selected"],
        "textarea": ["name", "placeholder", "disabled"],
        // Lowercase: attribute names are lowercased before this lookup (see `rebuildOpenTag`),
        // and WebKit's own HTML parser re-cases known SVG attributes back to camelCase for us
        // (the HTML5 "adjust foreign attributes" step) regardless of what case we emit.
        "svg": ["xmlns", "viewbox", "preserveaspectratio"],
        "g": ["transform", "fill", "stroke"],
        "path": ["d", "fill", "stroke", "stroke-width", "transform"],
        "rect": ["x", "y", "width", "height", "rx", "ry", "fill", "stroke", "stroke-width", "transform"],
        "circle": ["cx", "cy", "r", "fill", "stroke", "stroke-width", "transform"],
        "ellipse": ["cx", "cy", "rx", "ry", "fill", "stroke", "stroke-width", "transform"],
        "line": ["x1", "y1", "x2", "y2", "stroke", "stroke-width", "transform"],
        "polyline": ["points", "fill", "stroke", "stroke-width", "transform"],
        "polygon": ["points", "fill", "stroke", "stroke-width", "transform"],
        "text": ["x", "y", "font-family", "font-size", "text-anchor", "fill", "transform"],
        "tspan": ["x", "y", "font-family", "font-size", "fill"],
    ]

    static func sanitize(_ html: String) -> String {
        var output = ""
        output.reserveCapacity(html.count)
        var skipDepth: [String] = []   // stack of dropWithContent tags currently being skipped

        for token in HTMLTokenizer.tokenize(html) {
            switch token {
            case .text(let text):
                if skipDepth.isEmpty {
                    output += text
                }
            case .comment:
                continue   // never re-emitted: a comment can hide a conditional-comment-style payload
            case .openTag(let name, let attributes, let selfClosing):
                let lower = name.lowercased()
                if !skipDepth.isEmpty {
                    if dropWithContent.contains(lower) { skipDepth.append(lower) }
                    continue
                }
                if dropWithContent.contains(lower) {
                    if !selfClosing { skipDepth.append(lower) }
                    continue
                }
                guard allowedTags.contains(lower) else { continue }   // tag dropped, text kept by .text case
                if let rebuilt = rebuildOpenTag(name: lower, attributes: attributes, selfClosing: selfClosing) {
                    output += rebuilt
                }
            case .closeTag(let name):
                let lower = name.lowercased()
                if !skipDepth.isEmpty {
                    if skipDepth.last == lower { skipDepth.removeLast() }
                    continue
                }
                guard allowedTags.contains(lower) else { continue }
                output += "</\(lower)>"
            }
        }
        return output
    }

    /// Returns nil when the tag itself must be dropped even though its tag name is allowed (an
    /// empty `<link>` once its only `rel` tokens were speculative, or a `<meta http-equiv>` that
    /// is not on the tiny safe list).
    private static func rebuildOpenTag(name: String, attributes: [(String, String)], selfClosing: Bool) -> String? {
        var kept: [(String, String)] = []
        let perTag = perTagAttributeAllowlist[name] ?? []

        for (rawKey, value) in attributes {
            let key = rawKey.lowercased()
            if key.hasPrefix("on") { continue }   // every event handler, belt-and-suspenders over the CSP

            switch (name, key) {
            case ("a", "href"), ("a", "ping"):
                continue   // #912 design call: the element stays (link text renders), the target does not
            case ("link", "rel"):
                let tokens = value.split(separator: " ").map { $0.lowercased() }.filter { !$0.isEmpty }
                let safe = tokens.filter { !speculativeRelTokens.contains($0) }
                if safe.isEmpty { return nil }   // nothing left but speculative hints: drop the whole tag
                kept.append((key, safe.joined(separator: " ")))
            case ("link", "href"):
                kept.append((key, value))
            case ("meta", "http-equiv"):
                return nil   // refresh, CSP override via meta, etc. — no http-equiv value is safe to keep
            case ("img", "src"), ("source", "src"):
                guard value.hasPrefix("data:") else { continue }   // #904: zero network loads is the claim
                kept.append((key, value))
            case ("form", "action"):
                continue   // CSP's form-action 'none' already blocks the submit; drop the target too
            default:
                if globalAttributeAllowlist.contains(key) || perTag.contains(key) {
                    kept.append((key, value))
                }
            }
        }

        if name == "link" && !kept.contains(where: { $0.0 == "rel" }) {
            // Every rel token was speculative (and so already returned nil above) OR there was no
            // rel at all — a `<link>` with no rel is not a recognizable safe use, drop it.
            return nil
        }

        var out = "<\(name)"
        for (key, value) in kept {
            out += " \(key)=\"\(escapeAttribute(value))\""
        }
        out += selfClosing ? " />" : ">"
        return out
    }

    private static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// A tolerant HTML tokenizer: enough state to split `<tag attr="value" attr2=value2 />`,
/// `</tag>`, `<!-- comment -->` and plain text apart, without needing a full DOM. Attribute
/// values may be double-quoted, single-quoted, or bare (`rel=stylesheet`); whitespace around `=`
/// and between attributes is tolerated, matching real hostile markup rather than the canonical
/// spelling (#912's own fixture of hint forms).
enum HTMLTokenizer {
    enum Token {
        case text(String)
        case comment(String)
        case openTag(name: String, attributes: [(String, String)], selfClosing: Bool)
        case closeTag(name: String)
    }

    static func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(html)
        var i = 0
        var textBuffer = ""

        func flushText() {
            if !textBuffer.isEmpty {
                tokens.append(.text(textBuffer))
                textBuffer = ""
            }
        }

        while i < chars.count {
            if chars[i] == "<" {
                if matches(chars, at: i, "<!--") {
                    flushText()
                    let end = findCommentEnd(chars, from: i + 4)
                    tokens.append(.comment(String(chars[(i + 4)..<min(end, chars.count)])))
                    i = end + 3
                    continue
                }
                if let (token, next) = parseTag(chars, from: i) {
                    flushText()
                    tokens.append(token)
                    i = next
                    continue
                }
            }
            textBuffer.append(chars[i])
            i += 1
        }
        flushText()
        return tokens
    }

    private static func matches(_ chars: [Character], at i: Int, _ s: String) -> Bool {
        let s = Array(s)
        guard i + s.count <= chars.count else { return false }
        for j in 0..<s.count where chars[i + j] != s[j] { return false }
        return true
    }

    private static func findCommentEnd(_ chars: [Character], from start: Int) -> Int {
        var i = start
        while i < chars.count {
            if matches(chars, at: i, "-->") { return i }
            i += 1
        }
        return chars.count
    }

    /// Parses one `<...>` construct starting at `<`. Returns nil (treated as stray text) if it
    /// never finds a closing `>` — an unterminated tag at end-of-input is text, not a tag.
    private static func parseTag(_ chars: [Character], from start: Int) -> (Token, Int)? {
        var i = start + 1
        guard i < chars.count else { return nil }

        let isClosing = chars[i] == "/"
        if isClosing { i += 1 }

        var name = ""
        while i < chars.count, isNameChar(chars[i]) {
            name.append(chars[i])
            i += 1
        }
        guard !name.isEmpty else { return nil }

        if isClosing {
            while i < chars.count, chars[i] != ">" { i += 1 }
            guard i < chars.count else { return nil }
            return (.closeTag(name: name), i + 1)
        }

        var attributes: [(String, String)] = []
        var selfClosing = false
        while i < chars.count {
            skipWhitespace(chars, &i)
            if i >= chars.count { return nil }
            if chars[i] == ">" { return (.openTag(name: name, attributes: attributes, selfClosing: selfClosing), i + 1) }
            if chars[i] == "/" {
                selfClosing = true
                i += 1
                continue
            }
            guard isNameChar(chars[i]) else { i += 1; continue }   // tolerate stray punctuation

            var attrName = ""
            while i < chars.count, isNameChar(chars[i]) || chars[i] == "-" || chars[i] == ":" {
                attrName.append(chars[i])
                i += 1
            }
            skipWhitespace(chars, &i)

            guard i < chars.count, chars[i] == "=" else {
                attributes.append((attrName, ""))   // boolean attribute: `disabled`, `checked`
                continue
            }
            i += 1
            skipWhitespace(chars, &i)
            guard i < chars.count else { return nil }

            var value = ""
            if chars[i] == "\"" || chars[i] == "'" {
                let quote = chars[i]
                i += 1
                while i < chars.count, chars[i] != quote {
                    value.append(chars[i])
                    i += 1
                }
                i += 1   // past the closing quote (or past end, harmlessly, if unterminated)
            } else {
                while i < chars.count, !chars[i].isWhitespace, chars[i] != ">" {
                    value.append(chars[i])
                    i += 1
                }
            }
            attributes.append((attrName, value))
        }
        return nil
    }

    private static func isNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    private static func skipWhitespace(_ chars: [Character], _ i: inout Int) {
        while i < chars.count, chars[i].isWhitespace { i += 1 }
    }
}
