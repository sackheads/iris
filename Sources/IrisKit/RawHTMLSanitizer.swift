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
///
/// **Scope (dev-3's #915 review finding 3): this closes the dns-prefetch/speculative-load class
/// specifically, not every network channel.** `ViewerConfiguration`'s CSP (`default-src 'none'`)
/// is still what blocks an ordinary subresource load (an external stylesheet, an `<img src>` this
/// sanitizer didn't need to touch, CSS `@import`); this sanitizer and the CSP are a stack, not
/// alternatives — a document that reaches WebKit only through this sanitizer's output, with no
/// CSP behind it, is not the production configuration and not a claim this file makes.
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
        // `srcset` deliberately absent (#915 review finding 3): it is a list of candidate URLs,
        // not one value `src`'s data:-only check can cover, and a responsive image is not a
        // use case this phase-1 viewer needs to carry.
        "source": ["src", "type"],
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
                // dev-3's #915 review finding 1: HTML splits an ASCII-whitespace-separated
                // attribute list on tab/LF/FF/CR too, not just space. `rel="foo\tpreconnect"`
                // was one token to a space-only split (so `preconnect` survived verbatim) and two
                // tokens to WebKit, which preconnected. Split on the same set WebKit does.
                let tokens = splitASCIIWhitespace(value).map { $0.lowercased() }
                let safe = tokens.filter { !speculativeRelTokens.contains($0) }
                if safe.isEmpty { return nil }   // nothing left but speculative hints: drop the whole tag
                kept.append((key, safe.joined(separator: " ")))
            case ("link", "href"):
                // #915 review finding 3: an external stylesheet/icon href loads a resource with
                // no speculative hint involved at all — this sanitizer closes the dns-prefetch
                // class, not every network channel (the CSP's `default-src 'none'` carries the
                // rest in production), but it should not hand back a channel of its own either.
                guard value.hasPrefix("data:") else { continue }
                kept.append((key, value))
            case ("meta", "http-equiv"):
                return nil   // refresh, CSP override via meta, etc. — no http-equiv value is safe to keep
            case ("img", "src"), ("source", "src"):
                guard value.hasPrefix("data:") else { continue }   // #904: zero network loads is the claim
                kept.append((key, value))
            case ("form", "action"):
                continue   // CSP's form-action 'none' already blocks the submit; drop the target too
            case (_, "style"):
                // #915 review finding 3: `style="background:url(https://...)"` / `image-set(...)`
                // loads without any speculative hint. Not a CSS parse — a conservative containment
                // check that drops the whole declaration rather than trying to tell a `data:` url()
                // apart from a network one.
                guard !containsExternalURLFunction(value) else { continue }
                kept.append((key, value))
            case (_, "fill"), (_, "stroke"):
                // Same finding, for SVG: `fill="url(https://...)"` references an external paint
                // server. `url(#id)` (a same-document fragment) is left alone.
                guard !containsExternalURLFunction(value) else { continue }
                kept.append((key, value))
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

    /// Scalar-by-scalar, not `replacingOccurrences` (#915 review finding 2): `String` equality
    /// and substring search are grapheme-cluster-based, which combines a bare `"` with a
    /// following combining mark into one Character that is not `"` and so is never matched or
    /// escaped — writing the quote back out unescaped and letting whatever follows close the
    /// attribute value early, outside the allow-list entirely. Iterating `unicodeScalars`
    /// matches what the tokenizer below now does, and what WebKit's own parser does.
    private static func escapeAttribute(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "\"": out.append(contentsOf: "&quot;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// ASCII whitespace per the HTML spec (tab, LF, FF, CR, space) — the same set a browser
    /// splits an attribute's whitespace-separated token list on. `String.split` on a single
    /// `Character` separator only catches literal spaces (#915 review finding 1).
    private static func splitASCIIWhitespace(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if isASCIIWhitespace(scalar) {
                if !current.isEmpty {
                    tokens.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { tokens.append(String(current)) }
        return tokens
    }

    private static func isASCIIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0C, 0x0D, 0x20: return true
        default: return false
        }
    }

    /// A conservative containment check, not a CSS/URL parse (#915 review finding 3): true
    /// whenever the value has a `url(`/`image-set(` function call that isn't a same-document
    /// fragment (`url(#id)`), which is the shape that loads a network resource from a `style`
    /// attribute or an SVG `fill`/`stroke` without going through any tag/attribute this sanitizer
    /// otherwise value-checks.
    private static func containsExternalURLFunction(_ value: String) -> Bool {
        let lowered = value.lowercased()
        for marker in ["url(", "image-set("] {
            var searchStart = lowered.startIndex
            while let range = lowered.range(of: marker, range: searchStart..<lowered.endIndex) {
                let afterParen = range.upperBound
                let isFragment = afterParen < lowered.endIndex
                    && (lowered[afterParen] == "#" || (lowered[afterParen] == "'" || lowered[afterParen] == "\"")
                        && lowered.index(after: afterParen) < lowered.endIndex
                        && lowered[lowered.index(after: afterParen)] == "#")
                if !isFragment { return true }
                searchStart = afterParen
            }
        }
        return false
    }
}

/// A tolerant HTML tokenizer: enough state to split `<tag attr="value" attr2=value2 />`,
/// `</tag>`, `<!-- comment -->` and plain text apart, without needing a full DOM. Attribute
/// values may be double-quoted, single-quoted, or bare (`rel=stylesheet`); whitespace around `=`
/// and between attributes is tolerated, matching real hostile markup rather than the canonical
/// spelling (#912's own fixture of hint forms).
///
/// Walks `unicodeScalars`, not `Character`s (#915 review finding 2): Swift's `Character` is an
/// extended grapheme cluster, so a quote (`"`) immediately followed by a combining mark (e.g.
/// U+0301) is ONE `Character` that is not equal to `"` — the quote-matching loop below never saw
/// the value end there, and kept consuming attribute text WebKit does not, desyncing where this
/// tokenizer thinks a value ends from where WebKit's own (code-point-level) parser ends it. A
/// scalar is never merged with what follows, so this cannot happen at that granularity.
enum HTMLTokenizer {
    enum Token {
        case text(String)
        case comment(String)
        case openTag(name: String, attributes: [(String, String)], selfClosing: Bool)
        case closeTag(name: String)
    }

    static func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        let scalars = Array(html.unicodeScalars)
        var i = 0
        var textBuffer = String.UnicodeScalarView()

        func flushText() {
            if !textBuffer.isEmpty {
                tokens.append(.text(String(textBuffer)))
                textBuffer = String.UnicodeScalarView()
            }
        }

        while i < scalars.count {
            if scalars[i] == "<" {
                if matches(scalars, at: i, "<!--") {
                    flushText()
                    let end = findCommentEnd(scalars, from: i + 4)
                    tokens.append(.comment(String(String.UnicodeScalarView(scalars[(i + 4)..<min(end, scalars.count)]))))
                    i = end + 3
                    continue
                }
                if let (token, next) = parseTag(scalars, from: i) {
                    flushText()
                    tokens.append(token)
                    i = next
                    continue
                }
            }
            textBuffer.append(scalars[i])
            i += 1
        }
        flushText()
        return tokens
    }

    private static func matches(_ scalars: [Unicode.Scalar], at i: Int, _ s: String) -> Bool {
        let needle = Array(s.unicodeScalars)
        guard i + needle.count <= scalars.count else { return false }
        for j in 0..<needle.count where scalars[i + j] != needle[j] { return false }
        return true
    }

    private static func findCommentEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var i = start
        while i < scalars.count {
            if matches(scalars, at: i, "-->") { return i }
            i += 1
        }
        return scalars.count
    }

    /// Parses one `<...>` construct starting at `<`. Returns nil (treated as stray text) if it
    /// never finds a closing `>` — an unterminated tag at end-of-input is text, not a tag.
    private static func parseTag(_ scalars: [Unicode.Scalar], from start: Int) -> (Token, Int)? {
        var i = start + 1
        guard i < scalars.count else { return nil }

        let isClosing = scalars[i] == "/"
        if isClosing { i += 1 }

        var name = String.UnicodeScalarView()
        while i < scalars.count, isNameChar(scalars[i]) {
            name.append(scalars[i])
            i += 1
        }
        guard !name.isEmpty else { return nil }
        let nameString = String(name)

        if isClosing {
            while i < scalars.count, scalars[i] != ">" { i += 1 }
            guard i < scalars.count else { return nil }
            return (.closeTag(name: nameString), i + 1)
        }

        var attributes: [(String, String)] = []
        var selfClosing = false
        while i < scalars.count {
            skipWhitespace(scalars, &i)
            if i >= scalars.count { return nil }
            if scalars[i] == ">" { return (.openTag(name: nameString, attributes: attributes, selfClosing: selfClosing), i + 1) }
            if scalars[i] == "/" {
                selfClosing = true
                i += 1
                continue
            }
            guard isNameChar(scalars[i]) else { i += 1; continue }   // tolerate stray punctuation

            var attrName = String.UnicodeScalarView()
            while i < scalars.count, isNameChar(scalars[i]) || scalars[i] == "-" || scalars[i] == ":" {
                attrName.append(scalars[i])
                i += 1
            }
            skipWhitespace(scalars, &i)

            guard i < scalars.count, scalars[i] == "=" else {
                attributes.append((String(attrName), ""))   // boolean attribute: `disabled`, `checked`
                continue
            }
            i += 1
            skipWhitespace(scalars, &i)
            guard i < scalars.count else { return nil }

            var value = String.UnicodeScalarView()
            if scalars[i] == "\"" || scalars[i] == "'" {
                let quote = scalars[i]
                i += 1
                while i < scalars.count, scalars[i] != quote {
                    value.append(scalars[i])
                    i += 1
                }
                i += 1   // past the closing quote (or past end, harmlessly, if unterminated)
            } else {
                while i < scalars.count, !isASCIIWhitespaceScalar(scalars[i]), scalars[i] != ">" {
                    value.append(scalars[i])
                    i += 1
                }
            }
            attributes.append((String(attrName), String(value)))
        }
        return nil
    }

    private static func isNameChar(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 0x41 && s.value <= 0x5A) || (s.value >= 0x61 && s.value <= 0x7A) || (s.value >= 0x30 && s.value <= 0x39)
    }

    private static func skipWhitespace(_ scalars: [Unicode.Scalar], _ i: inout Int) {
        while i < scalars.count, isASCIIWhitespaceScalar(scalars[i]) { i += 1 }
    }

    private static func isASCIIWhitespaceScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A, 0x0C, 0x0D, 0x20: return true
        default: return false
        }
    }
}
