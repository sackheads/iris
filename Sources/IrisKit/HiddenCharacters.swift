import Foundation

extension String {
    /// True when the text contains a character a person reading it could not see (#334): a newline,
    /// carriage return or other control character, a format character (bidi overrides, zero-width),
    /// or a line/paragraph separator. Any of these can push or disguise a tail like `; curl x | sh`
    /// out of view, so a command carrying one cannot have been approved by being shown.
    var containsHiddenCharacters: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }
}

extension Unicode.Scalar {
    /// True for a scalar that reads as a quotation mark, so a name wrapped in `“…”` could use it
    /// to appear to close its own quotes (`xˮ is fine. Tap Open “y`). The one set both quoters use
    /// (`Briefing.name`, `NotificationPolicy.quoted`). A denylist: Unicode's `Quotation_Mark`
    /// misses primes, modifier letters and ornaments, so they are listed by hand. The ASCII `'` is
    /// deliberately absent: it is what `flattenCardField` and `NotificationPolicy` replace quotes
    /// with, and it does not read as a closing double quote.
    var isQuoteLike: Bool { Self.quoteLike.contains(self) }

    private static let quoteLike: Set<Unicode.Scalar> = [
        "\u{0022}", "\u{0060}", "\u{00AB}", "\u{00B4}", "\u{00BB}",
        // Modifier letters: prime, double prime, turned comma, apostrophe, reversed comma,
        // double apostrophe; spacing double acute.
        "\u{02B9}", "\u{02BA}", "\u{02BB}", "\u{02BC}", "\u{02BD}", "\u{02EE}", "\u{02DD}",
        "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}",
        "\u{2032}", "\u{2033}", "\u{2034}", "\u{2035}", "\u{2036}", "\u{2037}", "\u{2057}",
        "\u{2039}", "\u{203A}",
        "\u{275B}", "\u{275C}", "\u{275D}", "\u{275E}", "\u{275F}", "\u{2760}",
        "\u{2E42}",
        "\u{3003}", "\u{300C}", "\u{300D}", "\u{300E}", "\u{300F}", "\u{301D}", "\u{301E}", "\u{301F}",
        "\u{FE41}", "\u{FE42}", "\u{FE43}", "\u{FE44}",
        "\u{FF02}", "\u{FF07}", "\u{FF40}", "\u{FF62}", "\u{FF63}",
        "\u{1F676}", "\u{1F677}", "\u{1F678}",
    ]
}
