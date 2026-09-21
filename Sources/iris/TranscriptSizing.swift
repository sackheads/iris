import AppKit
import Foundation

/// Pre-layout sizing for the subagent transcript sheet (#19).
///
/// A macOS `.sheet` takes its window size from its content's ideal size on the FIRST layout pass
/// and (before macOS 15's `presentationSizing`) never revisits it. A height measured with a
/// `GeometryReader` arrives one pass too late, so the sheet needs an estimate it can hand SwiftUI
/// up front. This is deliberately rough — the sheet scrolls when it underestimates and the
/// measured height replaces it where the platform can act on that — but it is close enough that a
/// three-line transcript opens as a small card and a long one opens tall.
enum TranscriptSizing {
    static let minSheetHeight: CGFloat = 160
    static let maxSheetHeight: CGFloat = 640
    /// Header row + divider allowance added on top of the content height.
    static let chromeHeight: CGFloat = 60

    /// Vertical allowance per message row outside its text: role caption, its spacing, the
    /// bubble/markdown padding, and the stack spacing to the next row.
    static let perMessageChrome: CGFloat = 40
    /// Horizontal space the stack padding, bubble padding and the role-side spacer take from the
    /// sheet width before text can wrap.
    static let horizontalInset: CGFloat = 96
    /// System rows (tool calls, events) render as compact cards that summarise their raw text —
    /// a 500-character `<untrusted_context>` block is two lines on screen — so their text counts
    /// for at most this much.
    static let systemRowTextCap: CGFloat = 48
    /// Characters of a system row measured before the cap applies (a few lines' worth at the
    /// sheet's width; more can't raise the result).
    static let systemRowMeasuredPrefix = 400

    private static var bodyFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }

    /// Estimated rendered height of the message stack when the sheet is `width` points wide.
    static func estimatedContentHeight(messages: [(role: ChatRole, content: String)], width: CGFloat) -> CGFloat {
        guard !messages.isEmpty else { return 0 }
        let textWidth = max(width - horizontalInset, 120)
        var total: CGFloat = 0
        for message in messages {
            let text: CGFloat
            if message.role == .system {
                // Capped rows only need enough text to reach the cap: measuring a full tool
                // payload with Core Text and then discarding it is the expensive part.
                text = min(textHeight(String(message.content.prefix(systemRowMeasuredPrefix)), width: textWidth),
                           systemRowTextCap)
            } else {
                text = textHeight(message.content, width: textWidth)
            }
            total += perMessageChrome + text
            // Past the sheet's maximum every further row is clamped away anyway.
            if total + chromeHeight >= maxSheetHeight { break }
        }
        return total.rounded(.up)
    }

    /// Content height clamped, with chrome, into the sheet's allowed band.
    static func sheetHeight(forContent content: CGFloat) -> CGFloat {
        min(max(content + chromeHeight, minSheetHeight), maxSheetHeight)
    }

    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: bodyFont])
        return rect.height.rounded(.up)
    }
}
