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
    /// to appear to close its own quotes (`xˮ is fine. Tap Open “y`). Rule-based, because a
    /// denylist of single scalars always had gaps: every initial or final punctuation mark (Pi,
    /// Pf), every modifier symbol (Sk: accents, primes, ticks), plus the explicit set below, which
    /// holds what those categories miss (Po, Lm and letter look-alikes such as ״ and the saltillo).
    /// Lm is deliberately not ruled out wholesale: it carries real letters in several scripts,
    /// and neither are the emoji skin-tone modifiers.
    /// The ASCII `'` is absent: it is what quotes are replaced with, and it does not read as a
    /// closing double quote.
    var isQuoteLike: Bool {
        // The skin-tone modifiers are Sk, but they draw as a colour on the emoji before them.
        if self == "'" || properties.isEmojiModifier { return false }
        switch properties.generalCategory {
        case .initialPunctuation, .finalPunctuation, .modifierSymbol: return true
        default: return Self.quoteLike.contains(self)
        }
    }

    private static let quoteLike: Set<Unicode.Scalar> = [
        "\u{0022}", "\u{0060}", "\u{00AB}", "\u{00B4}", "\u{00BB}",
        // Modifier letters: prime, double prime, turned comma, apostrophe, reversed comma,
        // double apostrophe; spacing double acute.
        "\u{02B9}", "\u{02BA}", "\u{02BB}", "\u{02BC}", "\u{02BD}", "\u{02EE}", "\u{02DD}",
        // Modifier letters vertical line, acute and grave accent: two in a row draw a `"`.
        "\u{02C8}", "\u{02CA}", "\u{02CB}",
        // Modifier letter low and middle double primes / acute (Sk, listed as a safety net).
        "\u{02F5}", "\u{02F6}",
        // Greek tonos, psili, koronis, oxia, varia, dasia; Armenian apostrophe.
        "\u{0384}", "\u{1FBD}", "\u{1FBF}", "\u{1FEF}", "\u{1FFD}", "\u{1FFE}", "\u{055A}",
        // Hebrew geresh and gershayim.
        "\u{05F3}", "\u{05F4}",
        // Latin saltillo (letters, so no category rule catches them).
        "\u{A78B}", "\u{A78C}",
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

extension String {
    /// The name with nothing left that could read as a quotation mark, for `Briefing.name`, whose
    /// agent-facing names must keep real Unicode. (Banners do not use this: `NotificationPolicy`
    /// keeps an ASCII allowlist.)
    /// 1. NFKC first, so a compatibility form (fullwidth, Greek oxia) is judged as what it folds to.
    /// 2. Every `isQuoteLike` scalar becomes a straight `'`.
    /// 3. Every default-ignorable scalar (it draws blank) is dropped, except a variation
    ///    selector on a base other than a `'`, before marks are judged, so a mark sees the base
    ///    it really draws on.
    /// 4. A combining mark (Mn, Me) is kept only on a letter (not a modifier letter, Lm) or digit
    ///    base: on a space, a `'`, an Lm such as `ˍ` or another symbol, U+030E or U+030B draws a
    ///    `"` (`" \u{030E}"`, `"ˍ\u{030E}"`). Marks stacked on one base are judged by that base,
    ///    so Thai and Indic clusters (whose bases are Lo) survive. The price of not counting Lm as
    ///    a base: an Arabic haraka on a tatweel (U+0640) is dropped (م ـَ ح reads مـح). Accepted;
    ///    do not restore Lm as a base.
    var quotesNeutralised: String {
        var out = String.UnicodeScalarView()
        var baseIsAlphanumeric = false
        // No base yet, or the last one was a neutralised quote: a variation selector there has
        // nothing to pick a look for, and between two `'` it only keeps them apart for the
        // `'{2,}` collapse while still drawing as `''` (#483).
        var baseIsQuoteOrNone = true
        for scalar in precomposedStringWithCompatibilityMapping.unicodeScalars {
            // A variation selector picks how its base draws (text or emoji), so it stays on one.
            if scalar.properties.isVariationSelector {
                if !baseIsQuoteOrNone { out.append(scalar) }
                continue
            }
            // Dropped: a default-ignorable scalar draws nothing, and some (the Hangul fillers)
            // are letters (Lo), so keeping one would give a following U+030E a blank "letter" to
            // sit on, and it would draw alone as a `"`.
            if scalar.properties.isDefaultIgnorableCodePoint { continue }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark:
                if baseIsAlphanumeric { out.append(scalar) }
            case .spacingMark:
                // A vowel sign or the like: part of the cluster, so it leaves the base as it was.
                out.append(scalar)
            case let category:
                if scalar.isQuoteLike {
                    out.append("'")
                    baseIsAlphanumeric = false
                    baseIsQuoteOrNone = true
                } else {
                    out.append(scalar)
                    baseIsAlphanumeric = Self.alphanumeric.contains(category)
                    baseIsQuoteOrNone = scalar == "'"   // a straight one, which is not "quote-like"
                }
            }
        }
        return String(out)
    }

    private static let alphanumeric: Set<Unicode.GeneralCategory> = [
        .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter,
        .decimalNumber,
    ]
}
