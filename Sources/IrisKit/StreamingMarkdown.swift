import SwiftUI
import MarkdownUI

/// A streaming reply as completed blocks and a live tail (#541 fix D; see `StreamingBlocks`).
/// The block list and the tail are separate views over the box, so a token re-evaluates only the
/// tail; each completed block is `Equatable` on its text and keyed by its index, so SwiftUI skips
/// it on every later token, and nothing re-parses it.
struct StreamingMarkdown: View {
    let box: StreamingTexts.Box

    /// The gap between two blocks rendered as separate Markdown views, matching MarkdownUI's own
    /// gap between blocks of one document (measured in `StreamingMarkdownTests`).
    static let blockSpacing: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: Self.blockSpacing) {
            StreamedBlocks(box: box)
            StreamedTail(box: box)
        }
    }
}

private struct StreamedBlocks: View {
    let box: StreamingTexts.Box
    var body: some View {
        ForEach(Array(box.blocks.enumerated()), id: \.offset) { _, text in
            CompletedBlock(text: text).equatable()
        }
    }
}

private struct StreamedTail: View {
    let box: StreamingTexts.Box
    var body: some View {
        if !box.tail.isEmpty { Markdown(box.tail) }
    }
}

/// One block that will not change again.
struct CompletedBlock: View, Equatable {
    let text: String
    #if DEBUG
    /// How often each block's body ran, for the test that a completed block is never re-evaluated.
    nonisolated(unsafe) static var bodyCounts: [String: Int] = [:]
    #endif
    var body: some View {
        #if DEBUG
        let _ = Self.bodyCounts[text, default: 0] += 1
        #endif
        Markdown(text)
    }
}
