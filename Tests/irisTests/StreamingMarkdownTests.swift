import Testing
import AppKit
import SwiftUI
import Foundation
@testable import IrisKit

/// #541 fix D's row: a completed block is never re-evaluated by a later token, and the split
/// renders like the whole message, so the final write changes nothing the eye can see.
@MainActor
@Suite("Streaming reply rendered as blocks (#541)")
struct StreamingMarkdownTests {
    private func host<V: View>(_ view: V, width: CGFloat = 600) -> NSHostingView<V> {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 2000),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = window.contentView!.bounds
        window.contentView!.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    @Test("a token re-evaluates the tail only: a completed block's body never runs again")
    func completedBlocksStayPut() async throws {
        let first = "First paragraph, done."
        let second = "- a list\n- that is done"
        let start = "\(first)\n\n\(second)\n\nThe tail starts\nand"
        let box = StreamingTexts.Box(conversationId: UUID(), text: start)
        #expect(box.blocks.map { $0.trimmingCharacters(in: .newlines) } == [first, second],
                "precondition: two completed blocks")
        let (firstBlock, secondBlock) = (box.blocks[0], box.blocks[1])
        let hosting = host(StreamingMarkdown(box: box))
        try await Task.sleep(nanoseconds: 50_000_000)
        hosting.layoutSubtreeIfNeeded()
        let before = (CompletedBlock.bodyCounts[firstBlock] ?? 0, CompletedBlock.bodyCounts[secondBlock] ?? 0)
        #expect(before.0 >= 1 && before.1 >= 1, "precondition: the blocks rendered")

        var text = start
        for word in [" and", " grows", " word", " by", " word."] {
            text += word
            box.update(text)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(box.blocks == [firstBlock, secondBlock], "the tail grew; nothing was cut")
        #expect(CompletedBlock.bodyCounts[firstBlock] == before.0, "first block re-evaluated by a token")
        #expect(CompletedBlock.bodyCounts[secondBlock] == before.1, "second block re-evaluated by a token")
    }

    /// Renders `view` at a fixed width, for a pixel comparison.
    private func render<V: View>(_ view: V) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: view.frame(width: 600, alignment: .leading)
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }

    @Test("split and whole render alike, so nothing jumps at the final write", arguments: 0..<3)
    func noJumpAtFinalWrite(doc: Int) throws {
        let text = StreamingBlocksTests.corpus[doc]
        let box = StreamingTexts.Box(conversationId: UUID(), text: text + "\n")
        #expect(box.blocks.count >= 2, "precondition: really split")
        let whole = try #require(render(CompletedBlock(text: text)))   // Markdown(text), as the final write renders
        let split = try #require(render(StreamingMarkdown(box: box)))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-541-pixels")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? whole.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("doc\(doc)-whole.png"))
        try? split.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("doc\(doc)-split.png"))
        print("[541pixels] doc \(doc): whole \(whole.pixelsWide)x\(whole.pixelsHigh), split \(split.pixelsWide)x\(split.pixelsHigh)")
        #expect(abs(whole.pixelsHigh - split.pixelsHigh) <= 2, "heights differ: the final write would jump")
        // And pixel by pixel: a block drawn anywhere else would show here.
        guard whole.pixelsHigh == split.pixelsHigh, whole.pixelsWide == split.pixelsWide else { return }
        var differing = 0
        for y in 0..<whole.pixelsHigh {
            for x in 0..<whole.pixelsWide where whole.colorAt(x: x, y: y) != split.colorAt(x: x, y: y) {
                differing += 1
            }
        }
        let fraction = Double(differing) / Double(whole.pixelsHigh * whole.pixelsWide)
        print("[541pixels] doc \(doc): \(differing) differing pixels (\(String(format: "%.4f", fraction * 100))%)")
        #expect(fraction < 0.001, "the split draws differently from the whole")
    }
}
