import Testing
import Foundation
@testable import IrisKit

/// #541 fix D: a streaming reply split into completed blocks and a live tail must read, to
/// MarkdownUI, exactly as the whole text does, at every point a stream passes through.
@Suite("Streaming reply split into blocks (#541)")
struct StreamingBlocksTests {
    /// Real-shaped replies and the CommonMark edges the cut rule exists for.
    static let corpus: [String] = [
        """
        The change touches the **dispatcher** and the `ToolExecutor`, so both need tests.

        - read the current config
        - compare it with the defaults
        - write only what differs

        ```swift
        let result = await executor.execute(name: "read_file", args: args)

        print(result)
        ```

        Once that is done, the remaining work is wiring.
        """,
        """
        ## Plan

        1. First step

        2. Second step, loose

           with a continuation paragraph

        3. Third

        Then a paragraph after the list.

        > A quote
        >
        > over two paragraphs

        > and a second quote

        ---

        | a | b |
        |---|---|
        | 1 | 2 |
        | 3 | 4 |

        Done.
        """,
        """
        - outer
          - inner

            ```
            code in a list

            with a blank line
            ```

        - next outer

        ~~~
        a tilde fence with ``` inside

        still code
        ~~~

            indented code after a blank

        paragraph
        """,
        """
        Setext heading
        ==============

        * star list

        + plus list

        10) paren list
        11) next

        Final words.
        """,
    ]

    /// Must render whole: a definition used before it, and HTML blocks that hold blank lines.
    static let unsplittable: [String] = [
        "See [the docs][d] first.\n\nMore text.\n\n[d]: https://example.com\n",
        "<pre>\nline one\n\nline two\n</pre>\n\nafter\n",
        "<!-- a comment\n\nover a blank -->\n\nafter\n",
        "<script>\nlet a = 1\n\nlet b = 2\n</script>\n\nafter\n",
    ]

    private func check(_ text: String, chunks: [Int]) {
        var splitter = StreamingBlocks()
        var end = text.startIndex
        var i = 0
        while end < text.endIndex {
            end = text.index(end, offsetBy: chunks[i % chunks.count], limitedBy: text.endIndex) ?? text.endIndex
            i += 1
            let prefix = String(text[..<end])
            let tail = splitter.update(prefix)
            let split = splitter.blocks.map(StreamingBlocks.html).joined() + StreamingBlocks.html(tail)
            if split != StreamingBlocks.html(prefix) {
                Issue.record("split differs at \(prefix.count) chars:\n--- prefix\n\(prefix)\n--- blocks \(splitter.blocks)\n--- tail\n\(tail)")
                return
            }
        }
    }

    @Test("every prefix of every reply reads the same split as whole, streamed one character at a time",
          arguments: 0..<corpus.count)
    func everyPrefix(doc: Int) {
        check(Self.corpus[doc], chunks: [1])
    }

    @Test("and streamed in uneven chunks, as a provider delivers", arguments: 0..<corpus.count)
    func unevenChunks(doc: Int) {
        check(Self.corpus[doc], chunks: [3, 17, 1, 40, 7])
    }

    @Test("the corpus is really split, or the equivalence proves nothing")
    func splits() {
        for doc in Self.corpus {
            var splitter = StreamingBlocks()
            _ = splitter.update(doc + "\n")
            #expect(splitter.blocks.count >= 2, "\(doc.prefix(40))…")
        }
    }

    @Test("a link reference definition or an HTML block keeps the whole text unsplit", arguments: 0..<unsplittable.count)
    func neverSplit(doc: Int) {
        let text = Self.unsplittable[doc]
        var splitter = StreamingBlocks()
        var tail = ""
        for end in text.indices.dropFirst() + [text.endIndex] {
            tail = splitter.update(String(text[..<end]))
        }
        #expect(splitter.disabled)
        #expect(splitter.blocks.isEmpty)
        #expect(tail == text)
        check(text, chunks: [1])
    }

    @Test("the scan is incremental: a long stream examines each byte once")
    func incrementalScan() {
        let reply = String(repeating: Self.corpus[0] + "\n\n", count: 20)
        var splitter = StreamingBlocks()
        var end = reply.startIndex
        while end < reply.endIndex {
            end = reply.index(end, offsetBy: 6, limitedBy: reply.endIndex) ?? reply.endIndex
            _ = splitter.update(String(reply[..<end]))
        }
        #expect(splitter.scannedBytes <= reply.utf8.count, "\(splitter.scannedBytes) scanned for \(reply.utf8.count)")
    }
}
