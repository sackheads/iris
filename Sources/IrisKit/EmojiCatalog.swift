import Foundation

struct EmojiItem: Identifiable, Sendable, Equatable {
    var id: String { shortcode }
    let shortcode: String        // without colons, e.g. "wave"
    let glyph: String            // base glyph, e.g. "👋"
    let supportsSkinTone: Bool
}

enum SkinTone: Int, CaseIterable, Codable, Sendable {
    case none = 1, light = 2, mediumLight = 3, medium = 4, mediumDark = 5, dark = 6

    /// Unified codepoint of the Fitzpatrick modifier, or nil for `.none`.
    var codepoint: String? {
        switch self {
        case .none: return nil
        case .light: return "1F3FB"
        case .mediumLight: return "1F3FC"
        case .medium: return "1F3FD"
        case .mediumDark: return "1F3FE"
        case .dark: return "1F3FF"
        }
    }

    static func fromModifier(_ name: String) -> SkinTone? {
        let prefix = "skin-tone-"
        guard name.hasPrefix(prefix), let n = Int(name.dropFirst(prefix.count)),
              let tone = SkinTone(rawValue: n), tone != .none else { return nil }
        return tone
    }
}

final class EmojiCatalog: @unchecked Sendable {
    static let shared = EmojiCatalog()

    private var glyphByCode: [String: String] = [:]                 // shortcode -> base glyph
    private var tonedGlyphByCode: [String: [String: String]] = [:]  // shortcode -> tone codepoint -> glyph
    private(set) var items: [EmojiItem] = []                        // one entry per alias, ordered

    init(url: URL? = Bundle.module.url(forResource: "emoji", withExtension: "json")) {
        guard let url else {
            print("WARNING: [EmojiCatalog] Could not locate resource 'emoji.json' in bundle.")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            load(data)
        } catch {
            print("WARNING: [EmojiCatalog] Failed to read emoji data at \(url.path): \(error)")
        }
    }

    private struct RawEmoji: Decodable {
        let short_names: [String]
        let unified: String
        let skin_variations: [String: Variation]?
        struct Variation: Decodable { let unified: String }
    }

    private func load(_ data: Data) {
        do {
            let raw = try JSONDecoder().decode([RawEmoji].self, from: data)
            for e in raw {
                let base = Self.scalars(from: e.unified)
                var toned: [String: String] = [:]
                if let sv = e.skin_variations {
                    for (tone, v) in sv { toned[tone] = Self.scalars(from: v.unified) }
                }
                let supports = !toned.isEmpty
                for name in e.short_names {
                    glyphByCode[name] = base
                    if supports { tonedGlyphByCode[name] = toned }
                    items.append(EmojiItem(shortcode: name, glyph: base, supportsSkinTone: supports))
                }
            }
        } catch {
            print("WARNING: [EmojiCatalog] Failed to decode emoji JSON: \(error)")
        }
    }

    /// "1F44B-1F3FB" -> "👋🏻"
    static func scalars(from unified: String) -> String {
        var out = ""
        for part in unified.split(separator: "-") {
            if let v = UInt32(part, radix: 16), let scalar = Unicode.Scalar(v) {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Base glyph for a shortcode, applying `tone` when the emoji supports it.
    func glyph(for shortcode: String, tone: SkinTone = .none) -> String? {
        guard let base = glyphByCode[shortcode] else { return nil }
        guard tone != .none, let cp = tone.codepoint,
              let toned = tonedGlyphByCode[shortcode]?[cp] else { return base }
        return toned
    }

    /// Prefix search over all aliases: exact match first, then shorter, then alphabetical.
    func matches(prefix: String, limit: Int = 8) -> [EmojiItem] {
        let q = prefix.lowercased()
        guard !q.isEmpty else { return [] }
        let hits = items.filter { $0.shortcode.hasPrefix(q) }
        let ranked = hits.sorted {
            if ($0.shortcode == q) != ($1.shortcode == q) { return $0.shortcode == q }
            if $0.shortcode.count != $1.shortcode.count { return $0.shortcode.count < $1.shortcode.count }
            return $0.shortcode < $1.shortcode
        }
        return Array(ranked.prefix(limit))
    }
}
