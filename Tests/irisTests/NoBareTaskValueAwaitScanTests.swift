import Testing
import Foundation

/// #1162 / #428 / #1340: a test never waits where `.timeLimit` cannot reach it. Three shapes do:
/// - `await task.value` (or `.result`) on an unstructured task ignores the waiter's cancellation: `await t.value`,
///   `await self.t.value`, `await tasks[0].value`, `await t!.value`, `await Task.detached { … }.value`, or a
///   `}.value` on the line after the closure. Await it through `value(of:within:)` (`BoundedWait.swift`).
/// - a bare `withChecked`/`withUnsafe` (`Throwing`) `Continuation` waits for whatever resumes it, and nothing else.
/// - a blocking `.wait()` with no timeout, or one of `.distantFuture` (a semaphore, a group, a condition), parks a thread for good.
/// This scan reads every test source, subfolders included (`MCPProvider/`), and fails on any such line that has no
/// `// hang-ok: [<tag>] <reason>` marker, either trailing the line or on a comment-only line directly above it (#1388).
/// A line is exempt because it is bounded (named how), or because no wait happens there. A marker whose line waits on nothing fails too, so none outlives its wait. Not
/// `@MainActor`: a scan of every test file is heavy synchronous work (#642).
@Suite("Tests never wait where .timeLimit can't end them (#1162, #1340)", .timeLimit(.minutes(1)))
struct NoBareTaskValueAwaitScanTests {
    /// Every marker says which kind of safe its line is, so a reviewer can check each against its tag: `bounded`
    /// names the timer, race or bounded wait that ends it; `completion` is a system completion handler that is
    /// called with a result or an error; `not a task`, `synchronous` and `exit-test child` say why no wait exists.
    /// (`gate #1343`, a test-released gate, went with #1343's last gate: a test-held stub is a `TestGate` now.)
    static let reasonTags: Set<String> = ["bounded", "completion", "not a task", "synchronous", "exit-test child"]

    /// `// hang-ok: [<tag>] <reason>`: the tag, and the reason with surrounding space trimmed.
    private static let marker = try! NSRegularExpression(pattern: #"//\s*hang-ok:\s*\[([^\]]*)\]\s*(.*)$"#)

    private static let continuation = try! NSRegularExpression(pattern: #"\bwith(Checked|Unsafe)(Throwing)?Continuation\b"#)
    private static let blockingWait = try! NSRegularExpression(pattern: #"\.wait\(\s*\)|\.wait\([^)]*\bdistantFuture\b"#)
    /// `await` applied straight to a task's `.value`/`.result`: a plain chain (`t`, `self.t`, `t!`, `ts[0]`) or a
    /// `Task { … }` / `Task.detached { … }` closure. Not `.value(…)`, a call, and not a `.value` that is only an
    /// argument inside the awaited call (`await waitFor { ready.value != nil }`).
    private static let taskValue = try! NSRegularExpression(
        pattern: #"await\s+(?:try[?!]?\s+)?(?:[A-Za-z_][\w.!\[\]]*|Task(?:\.detached)?\s*(?:<[^>]*>)?\s*(?:\([^)]*\))?\s*\{.*\})\s*\.(value|result)\b(?!\s*\()"#)
    /// A closure's `.value` on the line after it: `}.value`, or a line that is only `.value`.
    private static let leadingValue = try! NSRegularExpression(pattern: #"^\}?\s*\.(value|result)\b(?!\s*\()"#)

    /// What the line does that `.timeLimit` can't end, or nil.
    static func kinds(of line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return [] }
        func hit(_ r: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
            r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        }
        var out: [String] = []
        if hit(continuation, line) != nil { out.append("bare continuation") }
        // An `await gate.wait()` is the gate's own async wait, caught at its continuation; only a blocking one counts.
        let range = NSRange(line.startIndex..., in: line)
        if blockingWait.matches(in: line, range: range).contains(where: { m in
            guard let r = Range(m.range, in: line) else { return false }
            return !line[..<r.lowerBound].contains("await")
        }) { out.append("blocking .wait() with no timeout") }
        if hit(leadingValue, trimmed) != nil || hit(taskValue, line) != nil { out.append("bare await of a task's value") }
        return out
    }

    /// The marker on `line`, if it has one: where it starts, its tag, and its reason.
    static func marker(in line: String) -> (at: String.Index, tag: String, reason: String)? {
        guard let m = marker.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let whole = Range(m.range, in: line), let tag = Range(m.range(at: 1), in: line),
              let reason = Range(m.range(at: 2), in: line) else { return nil }
        return (whole.lowerBound, String(line[tag]), line[reason].trimmingCharacters(in: .whitespaces))
    }

    /// The offences in one file's `text` (`file` is the path under `irisTests`): a flagged line with no marker, a
    /// marker with an unknown tag or no reason, and a marker that exempts no flagged line.
    static func offences(in text: String, file: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let markers = lines.map { marker(in: $0) }
        // A trailing marker's own text isn't code: its reason may well name a wait.
        let code = zip(lines, markers).map { line, mark in mark.map { String(line[..<$0.at]) } ?? line }
        let commentOnly = code.map { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        var out: [String] = []
        for (n, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let mark = markers[n] {
                if !reasonTags.contains(mark.tag) { out.append("\(file):\(n + 1): unknown hang-ok tag [\(mark.tag)]: \(trimmed)") }
                if mark.reason.isEmpty { out.append("\(file):\(n + 1): hang-ok marker with no reason: \(trimmed)") }
                let exempts = commentOnly[n] ? n + 1 < lines.count && !kinds(of: code[n + 1]).isEmpty : !kinds(of: code[n]).isEmpty
                if !exempts { out.append("\(file):\(n + 1): hang-ok marker on no wait: \(trimmed)") }
            }
            let kinds = kinds(of: code[n])
            guard !kinds.isEmpty else { continue }
            let marked = markers[n] != nil || (n > 0 && markers[n - 1] != nil && commentOnly[n - 1])
            if !marked { out.append("\(file):\(n + 1): \(kinds.joined(separator: ", ")): \(trimmed)") }
        }
        return out
    }

    /// The offences across `files` (path under `irisTests` → contents), and how many flagged lines they hold.
    static func scan(_ files: [(path: String, text: String)]) -> (offences: [String], flagged: Int) {
        var offences: [String] = [], flagged = 0
        for file in files {
            offences += Self.offences(in: file.text, file: file.path)
            flagged += file.text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                let line = String(line)
                return !kinds(of: marker(in: line).map { String(line[..<$0.at]) } ?? line).isEmpty
            }.count
        }
        return (offences, flagged)
    }

    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    static func testSources() throws -> [(path: String, text: String)] {
        let base = dir.standardizedFileURL.path + "/"
        let walk = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        var out: [(path: String, text: String)] = []
        for case let url as URL in walk where url.pathExtension == "swift" && url.lastPathComponent != "NoBareTaskValueAwaitScanTests.swift" {
            let path = url.standardizedFileURL.path
            out.append((path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    @Test("no test waits where .timeLimit can't end it, outside the lines marked hang-ok")
    func noUnboundedWait() throws {
        let files = try Self.testSources()
        #expect(files.count > 100, "the scan found the test sources")
        #expect(files.contains { $0.path.hasPrefix("MCPProvider/") }, "the scan reached a subfolder")
        let (found, flagged) = Self.scan(files)
        #expect(flagged > 0, "the scan flagged the marked lines")
        #expect(found.isEmpty, "a wait .timeLimit can't end (bound it, e.g. `value(of:within:)`, or mark it `// hang-ok: [<tag>] <reason>`, #428): \(found)")
    }

    @Test("the scan sees each shape, and ignores a bounded wait, an argument's .value and a comment")
    func scanSelfCheck() {
        for line in ["await fire.value", "#expect(await child.value.status == .x)", "await self.t.value", "await tasks[0].value",
                     "await t!.value", "x = await Task.detached { 1 }.value", "}.value", "let r = await caller.result",
                     "await withCheckedContinuation { c in", "try await withCheckedThrowingContinuation { c in",
                     "await withUnsafeContinuation { c in", "sema.wait()", "group.wait( )", "_ = sema.wait(timeout: .distantFuture)", "cond.wait(until: Date.distantFuture)"] {
            #expect(!Self.kinds(of: line).isEmpty, "\(line)")
        }
        for line in ["try await value(of: fire)", "// await fire.value is the thing to avoid", "await gate.wait()",
                     "_ = sema.wait(timeout: .now() + 5)", "#expect(await waitFor { ready.value != nil })",
                     "rec.value(forHTTPHeaderField: \"x\")", "await dispatch(call).result", "x.result.contains(\"y\")"] {
            #expect(Self.kinds(of: line).isEmpty, "\(line)")
        }
    }

    @Test("a hang-ok marker exempts its own line or the one below it, nothing further, and only with a known tag and a reason")
    func markers() {
        func offences(_ text: String) -> [String] { Self.offences(in: text, file: "A.swift") }
        #expect(offences("sema.wait() // hang-ok: [bounded] signalled by the timer\n").isEmpty, "trailing")
        #expect(offences("// hang-ok: [bounded] signalled by the timer\nsema.wait()\n").isEmpty, "directly above")
        #expect(offences("sema.wait()\n").count == 1, "an unmarked flagged line fails")
        #expect(offences("// hang-ok: [bounded] signalled by the timer\n\nsema.wait()\n").count == 2,
                "a marker two lines up exempts nothing, and is itself on no wait")
        #expect(offences("sema.wait() // hang-ok: [fine] trust me\n") == ["A.swift:1: unknown hang-ok tag [fine]: sema.wait() // hang-ok: [fine] trust me"])
        #expect(offences("sema.wait() // hang-ok: [bounded]   \n").count == 1, "a marker needs a reason")
        #expect(offences("let x = 1 // hang-ok: [bounded] it was a wait once\n").count == 1, "an orphan trailing marker fails")
        #expect(offences("// hang-ok: [bounded] it was a wait once\nlet x = 1\n").count == 1, "an orphan marker above fails")
        #expect(offences("ok() // hang-ok: [bounded] races `await task.value` against a timer\n").count == 1,
                "a trailing marker's reason isn't scanned as code, so naming a wait doesn't make it one")
        for tag in Self.reasonTags {
            #expect(offences("sema.wait() // hang-ok: [\(tag)] a reason\n").isEmpty, "\(tag)")
        }
    }
}
