import Testing
import Foundation
@testable import IrisKit

/// #709: every tool result the model sees, and so every tool result the guard judges, is held to
/// one size; `read_file` can read the rest by line; a command's output is drained bounded.
@Suite("Tool output caps (#709)", .timeLimit(.minutes(1)))
struct OutputCapTests {
    private func numbered(_ count: Int, width: Int = 40) -> String {
        (1...count).map { "line \($0) " + String(repeating: "x", count: width) }.joined(separator: "\n") + "\n"
    }

    // MARK: The cut

    @Test("a result within the cap is unchanged")
    func underCap() {
        let text = numbered(100)
        #expect(OutputCap.cap(text) == text)
    }

    @Test("a long result keeps whole lines from its head and tail, with a line counting bytes and lines")
    func headAndTail() throws {
        let text = numbered(5000)   // about 240 KB
        let capped = OutputCap.cap(text)
        #expect(capped.utf8.count <= OutputCap.limitBytes + 400)
        #expect(capped.hasPrefix("line 1 "))
        #expect(capped.hasSuffix("line 5000 " + String(repeating: "x", count: 40) + "\n"))
        let marker = try #require(capped.split(separator: "\n").first { $0.hasPrefix("[output truncated:") })
        #expect(marker.contains("of 5000 lines") && marker.contains("of \(text.utf8.count) bytes"))
        // Every kept line is whole: no line is cut mid-way.
        for line in capped.split(separator: "\n") where !line.hasPrefix("[output truncated:") {
            #expect(line.hasSuffix(String(repeating: "x", count: 40)), "\(line.prefix(60))")
        }
    }

    @Test("the cut never splits a UTF-8 character, even with no newline to cut on")
    func utf8Boundary() {
        // One ASCII byte first, so every 2-byte "é" starts at an odd offset and both cut points
        // (24 KB in, 8 KB from the end) land inside one.
        let text = "a" + String(repeating: "\u{e9}", count: OutputCap.limitBytes) + "b"
        let capped = OutputCap.cap(text)
        #expect(!capped.contains("\u{fffd}"))
        #expect(capped.hasPrefix("a\u{e9}") && capped.hasSuffix("\u{e9}b"))
    }

    @Test("a cut moves to a line boundary only when one is near: a short line and a huge one keep a full head and tail")
    func snapIsBounded() {
        let huge = String(repeating: "z", count: 2_000_000)
        let headFirst = OutputCap.cap("ab\n" + huge)
        let kept = headFirst.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(headFirst.utf8.count > OutputCap.limitBytes - OutputCap.snapBytes, "the head wasn't cut back to the first line")
        #expect(kept.first == "ab")
        let tailLast = OutputCap.cap(huge + "\n" + "y")
        #expect(tailLast.hasSuffix(String(repeating: "z", count: 1000) + "\ny") || tailLast.utf8.count > OutputCap.limitBytes - OutputCap.snapBytes,
                "the tail wasn't cut forward to the last line")
        #expect(tailLast.utf8.count > OutputCap.limitBytes - OutputCap.snapBytes)
    }

    @Test("read_file's advice names the lines left out, counted in the file from the call's own start_line")
    func readFileAdvice() throws {
        let capped = OutputCap.cap(numbered(5000), advice: .readFile(startLine: 1))
        let marker = try #require(capped.split(separator: "\n").first { $0.hasPrefix("[output truncated:") })
        let shown = try #require(Int(marker.split(separator: " ")[5]))   // "showed the first N"
        #expect(marker.contains("read_file start_line=\(shown + 1)"))
        let fromLater = OutputCap.cap(numbered(5000), advice: .readFile(startLine: 101))
        #expect(fromLater.contains("start_line=\(shown + 101)"))
    }

    @Test("run_command's advice says to redirect to a file and read it by line")
    func runCommandAdvice() {
        #expect(OutputCap.cap(numbered(5000), advice: .runCommand).contains("redirect the output to a file"))
    }

    @Test("bytes a drain already dropped are counted, and line numbers are not offered then")
    func droppedBytes() {
        let capped = OutputCap.cap(numbered(5000), advice: .readFile(startLine: 1), droppedBytes: 1_000_000)
        #expect(capped.contains("at least 5000 lines"))
        #expect(!capped.contains("start_line="))
    }

    // MARK: read_file's range

    @Test("start_line and line_count pick lines; a start past the end says how many there are")
    func lineRange() throws {
        let text = "a\nb\nc\nd\n"
        let range = try #require(try LineRange.parse(start: .int(2), count: .int(2)).get())
        #expect(LineRange.apply(range, to: text) == "b\nc\n")
        #expect(LineRange.apply(LineRange(start: 3, count: nil), to: text) == "c\nd\n")
        #expect(LineRange.apply(LineRange(start: 9, count: nil), to: text).contains("has 4 lines"))
        #expect(try LineRange.parse(start: nil, count: nil).get() == nil)
        #expect(try LineRange.parse(start: .string("3"), count: nil).get() == LineRange(start: 3, count: nil))
        #expect(throws: ToolMessage.self) { try LineRange.parse(start: .int(0), count: nil).get() }
        #expect(throws: ToolMessage.self) { try LineRange.parse(start: .int(1), count: .string("lots")).get() }
    }

    @Test("read_file's schema and executor agree on start_line and line_count")
    func readFileSchemaAndExecutor() async throws {
        let tools = await ToolExecutor().getTools(workspaceToolsEnabled: false)
        let read = try #require(tools.first { $0.name == "read_file" })
        #expect(read.parameters?.properties?["start_line"] != nil && read.parameters?.properties?["line_count"] != nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-709-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
        let out = await ToolExecutor().execute(name: "read_file", args: ["path": .string(file.path), "start_line": .int(2), "line_count": .int(2)])
        #expect(out == "two\nthree\n")
        // A file whose text happens to look like a failure is still content, and still ranged.
        let lookalike = dir.appendingPathComponent("g.txt")
        try "Error: not really\nsecond\n".write(to: lookalike, atomically: true, encoding: .utf8)
        #expect(await ToolExecutor().execute(name: "read_file", args: ["path": .string(lookalike.path), "start_line": .int(2)]) == "second\n")
        // And a real failure isn't ranged.
        let missing = await ToolExecutor().execute(name: "read_file", args: ["path": .string(dir.appendingPathComponent("nope").path), "start_line": .int(2)])
        #expect(missing.hasPrefix("Error reading file:"))
    }

    // MARK: The drain

    @Test("a bounded stream keeps its head and its real end, and counts the middle it dropped")
    func boundedStream() {
        var stream = ProcessGroupRunner.BoundedStream(limit: 100, tailLimit: 10)
        let bytes = Array(repeating: UInt8(ascii: "a"), count: 500) + Array("END-OF-RUN".utf8)
        bytes.withUnsafeBytes { stream.append($0) }
        #expect(stream.kept.count == 100)
        #expect(String(decoding: stream.kept.suffix(10), as: UTF8.self) == "END-OF-RUN")
        #expect(stream.dropped == 410)
    }

    @Test("a command past the drain cap runs to its end, keeps its last line, and counts the drop")
    func runnerDrains() async throws {
        let runner = ProcessGroupRunner(outputLimit: 64 * 1024)
        let outcome = await runner.run(executable: "/bin/sh",
                                       arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' a; echo; echo LAST-LINE"],
                                       environment: nil, currentDirectory: nil, timeoutSeconds: 30)
        let output = try outcome.get()
        #expect(output.status == 0)
        #expect(output.stdout.count == 64 * 1024)
        #expect(String(decoding: output.stdout.suffix(10), as: UTF8.self) == "LAST-LINE\n")
        #expect(output.droppedStdout == 3_000_000 + 1 + 10 - 64 * 1024)
    }

    // MARK: The guard's input

    /// A canary that records every prompt it's sent.
    private final class RecordingCanary: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String] = []
        var longest: Int { lock.withLock { prompts.map(\.utf8.count).max() ?? 0 } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            lock.withLock { prompts.append(prompt) }
            return "SAFE"
        }
    }

    @Test("the canary's prompt never carries more than the cap, however long the input")
    func canaryBackstop() async {
        let canary = RecordingCanary()
        let huge = String(repeating: "harmless text, line after line.\n", count: 160_000)   // about 5 MB
        _ = await CoreMLEvaluator.$scopedModel.withValue(.init(nil)) {
            await AuxiliaryModelManager.$scopedEngines.withValue(["canary": canary]) {
                await InjectionGuard.sanitize(huge, contextTag: "tool_output_x", maxTier: .tier3_canary, protectionEnabled: true)
            }
        }
        #expect(canary.longest > 0, "the canary was asked")
        #expect(canary.longest <= OutputCap.limitBytes + 1024, "\(canary.longest) bytes")
    }

    @Test("through the engine, a large read reaches the model capped, even a first-party read the guard skips")
    @MainActor
    func engineCapsToolResult() async throws {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        let id = state.createNewConversation(isBackground: false, select: true)
        // Under the test's own Iris home: read without asking, and exempt from the guard.
        let file = IrisPaths.default.root.appendingPathComponent("cap-\(UUID().uuidString).txt")
        try numbered(5000).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        func reply(_ part: Part) -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
        }
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: [
            reply(Part(functionCall: FunctionCall(name: "read_file", args: ["path": .string(file.path)]))),
            reply(Part(text: "done")),
        ]), retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("go", source: "UI", conversationId: id)
        let history = state.conversations.first { $0.id == id }?.history ?? []
        let result = history.flatMap(\.parts).compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.last ?? ""
        #expect(result.contains("[output truncated:"), "\(result.prefix(200))")
        #expect(result.utf8.count <= OutputCap.limitBytes + 400)
        #expect(result.contains("read_file start_line="))
    }

    @Test("a sandboxed command drains bounded too: the session asks the runtime for the drain cap")
    func sandboxRouteDrains() async {
        let runtime = MockRuntime()
        let manager = SandboxSessionManager(runtime: runtime, image: { "ubuntu:latest" })
        _ = await manager.run(command: "echo hi", conversationId: UUID(), workspace: "/ws")
        #expect(runtime.execLimits == [OutputCap.drainBytes])
    }

    /// A canary that flags any prompt holding `marker`.
    private final class MarkerCanary: AuxiliaryInferenceEngine, @unchecked Sendable {
        let marker: String
        init(_ marker: String) { self.marker = marker }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            prompt.contains(marker) ? "MALICIOUS" : "SAFE"
        }
    }

    @Test("with tier 2 skipped, a long input is cut to what tier 3 judged, so its unjudged middle never reaches the model (#731 review)")
    func skippedTier2CutsToJudged() async {
        let marker = "PLANTED-\(UUID().uuidString)"
        let filler = String(repeating: "an ordinary line of a long system event.\n", count: 1300)   // about 50 KB
        let text = filler + marker + "\n" + filler
        let outcome = await CoreMLEvaluator.$scopedModel.withValue(.init(nil)) {
            await AuxiliaryModelManager.$scopedEngines.withValue(["canary": MarkerCanary(marker)]) {
                await InjectionGuard.sanitize(text, contextTag: "system_event_x", maxTier: .tier3_canary, protectionEnabled: true)
            }
        }
        #expect(!outcome.contains(marker), "the middle the canary never saw went through")
        #expect(outcome.contains("[output truncated:"))
    }
}
