import Foundation

/// The string a conversation's title becomes at the OS layer (NSWindow title, hence the AX tree).
/// A title is derived from content nobody vetted (the first message) or set by the model
/// (`rename_conversation`), so it is cleaned where it leaves for the window, never at storage:
/// the sidebar keeps the stored title (#938). Nothing in Iris reads a window or AX title back, so
/// this is display hygiene, not a guard.
enum WindowTitle {
    static let maxLength = 80

    static func safe(_ title: String) -> String {
        var out = ""
        var lastWasSpace = true
        for scalar in title.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
                // Newlines and tabs are controls too; they read as a space, the rest vanish.
                if scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar == "\u{2028}" || scalar == "\u{2029}",
                   !lastWasSpace {
                    out.unicodeScalars.append(" "); lastWasSpace = true
                }
            case .spaceSeparator:
                if !lastWasSpace { out.unicodeScalars.append(" "); lastWasSpace = true }
            default:
                out.unicodeScalars.append(scalar); lastWasSpace = false
            }
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        // Scalars, not Characters: 5000 combining marks on one letter is one Character (#998 review).
        let scalars = trimmed.unicodeScalars
        guard scalars.count > maxLength else { return trimmed }
        var capped = String.UnicodeScalarView()
        capped.append(contentsOf: scalars.prefix(maxLength))
        return String(capped) + "..."
    }
}
