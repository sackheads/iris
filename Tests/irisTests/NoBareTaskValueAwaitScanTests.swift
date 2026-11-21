import Testing
import Foundation

/// #1162 / #428: a test never awaits an unstructured task bare. `await task.value` ignores the waiter's
/// cancellation, so `.timeLimit` cannot end a test parked on it, and one lost wakeup hangs the whole
/// serial run at zero CPU. Await it through `value(of:within:)` (`BoundedWait.swift`). This scan reads
/// the test sources for `await <name>.value` and fails on any that is not on the list below, each of
/// which is named with why it is safe. Not `@MainActor`: a scan of every test file is heavy synchronous
/// work (#642).
@Suite("Tests never await an unstructured task's value bare (#1162)", .timeLimit(.minutes(1)))
struct NoBareTaskValueAwaitScanTests {
    /// `file: receiver` pairs that are not an unbounded wait on a task.
    private static let allowed: Set<String> = [
        // The wait is inside `finished(_:within:)`, raced against a detached timer.
        "JobRetryTests.swift: task",
        // A watcher task: the test polls its result with a bounded yield loop and never awaits it.
        "SessionStatusTests.swift: ask",
        // An actor property, not a task.
        "LLMRetryTests.swift: counter",
        // Opt-in (`IRIS_REAL_VM`), skipped by default and in CI; its driver is a child process wrapper.
        "ExitNowRealVMTests.swift: driver",
    ]

    static func offences(in text: String, file: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"await\s+([A-Za-z_][A-Za-z0-9_]*)\.value\b"#)
        var out: [String] = []
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            let range = NSRange(line.startIndex..., in: line)
            for match in pattern.matches(in: String(line), range: range) {
                guard let r = Range(match.range(at: 1), in: line) else { continue }
                let receiver = String(line[r])
                if !allowed.contains("\(file): \(receiver)") { out.append("\(file):\(n + 1): await \(receiver).value") }
            }
        }
        return out
    }

    @Test("no test file awaits `<task>.value` bare outside the listed, bounded cases")
    func noBareAwait() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "NoBareTaskValueAwaitScanTests.swift" }
        #expect(files.count > 100, "the scan found the test sources")
        var found: [String] = []
        for file in files {
            found += Self.offences(in: try String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent)
        }
        #expect(found.isEmpty, "bare `await task.value` in a test (use `value(of:within:)`, #428): \(found)")
    }

    @Test("the scan sees a bare await, and ignores a bounded one and a comment")
    func scanSelfCheck() {
        #expect(Self.offences(in: "        await fire.value\n", file: "X.swift") == ["X.swift:1: await fire.value"])
        #expect(Self.offences(in: "        #expect(await child.value.status == .x)\n", file: "X.swift").count == 1)
        #expect(Self.offences(in: "        try await value(of: fire)\n", file: "X.swift").isEmpty)
        #expect(Self.offences(in: "        // await fire.value is the thing to avoid\n", file: "X.swift").isEmpty)
    }
}
