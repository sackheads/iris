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
