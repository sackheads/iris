import Testing
import Foundation
@testable import IrisKit

/// #364: command hooks run in a process group of their own, through `ProcessGroupRunner`. Before,
/// `Process` + `readDataToEndOfFile` deadlocked past 64 KB of output (and on a payload past 64 KB,
/// written to stdin before anything read it), never escalated to SIGKILL, and hung until a
/// background job that held the pipe exited.
///
/// Markers and `pgrep` as in `RunCommandProcessGroupTests`: every sleep carries a duration nothing
/// else would be sleeping for, and every test kills its markers on the way out.
@Suite("Hook process group", .timeLimit(.minutes(1)))
struct HookManagerProcessGroupTests {
    typealias P = RunCommandProcessGroupTests

    /// A `BeforeTool` hook running `command`, with its own config file.
    private func manager(_ command: String, timeout: Int? = nil, event: String = "BeforeTool",
                         matcher: String = "t") throws -> (HookManager, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-hook-pg-\(UUID().uuidString).json")
        var hook: [String: Any] = ["type": "command", "command": command]
        if let timeout { hook["timeout"] = timeout }
        let config: [String: Any] = ["hooks": [event: [["matcher": matcher, "hooks": [hook]]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: url)
        var m = HookManager()
        m.configPathOverride = url.path
        return (m, url)
    }

    @Test("output past 64 KB comes back whole")
    func largeOutput() async throws {
        let (m, url) = try manager(#"printf '{"x":"'; head -c 300000 /dev/zero | tr '\0' 'x'; printf '"}'"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let decision = await m.fireBeforeTool(toolName: "t", args: [:])
        guard case .proceed(let data?) = decision else { Issue.record("got \(decision)"); return }
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["x"]?.count == 300_000)
    }

    @Test("a payload past 64 KB reaches the hook's stdin whole while its output drains")
    func largePayloadRoundTrip() async throws {
        let (m, url) = try manager("cat")
        defer { try? FileManager.default.removeItem(at: url) }
        let big = String(repeating: "y", count: 300_000)
        let decision = await m.fireBeforeTool(toolName: "t", args: ["big": .string(big)])
        guard case .proceed(let data?) = decision else { Issue.record("got \(decision)"); return }
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["big"] == big)
    }

    @Test("a hook that ignores SIGTERM is killed within the grace after its timeout")
    func timeoutEscalatesToSigkill() async throws {
        let nap = P.marker()
        defer { P.killAll(nap) }
        let (m, url) = try manager("trap '' TERM; sleep \(nap); true", timeout: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let started = Date()
        let decision = await m.fireBeforeTool(toolName: "t", args: [:])
        let wall = Date().timeIntervalSince(started)
        // A hook its timeout killed blocks: it never gave its verdict (#452).
        guard case .block = decision else { Issue.record("got \(decision)"); return }
        #expect(wall < 1 + ProcessGroupRunner.terminateGraceSeconds + 2, "returned after \(wall)s")
        #expect(await P.gone("sleep \(nap)", within: 2), "sleep \(nap) outlived the SIGKILL")
    }

    /// #452: a hook killed by its timeout can still exit 0 — through its trap, as here, or when
    /// the group SIGKILL ends its child an instant before the shell. Read by status alone, that
    /// was a proceed, and a `BeforeTool` hook that would have blocked let the tool through.
    @Test("a gating hook that exits 0 when its timeout kills it does not let the tool through")
    func killedHookDoesNotProceed() async throws {
        let nap = P.marker()
        defer { P.killAll(nap) }
        let (m, url) = try manager(#"trap 'echo "{\"x\":\"y\"}"; exit 0' TERM; sleep \#(nap)"#, timeout: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let decision = await m.fireBeforeTool(toolName: "t", args: [:])
        guard case .block(let reason) = decision else { Issue.record("a timed-out hook let the tool through: \(decision)"); return }
        #expect(reason == "Hook timed out after 1 seconds")
        #expect(await P.gone("sleep \(nap)", within: 2), "sleep \(nap) outlived the timeout")
    }

    /// #452: an `AfterTool` hook may be redacting the result on its way to the provider. One its
    /// timeout killed blocks rather than letting the unredacted result through.
    @Test("an AfterTool hook that exits 0 when its timeout kills it blocks the result")
    func killedAfterToolHookBlocks() async throws {
        let nap = P.marker()
        defer { P.killAll(nap) }
        let (m, url) = try manager(#"trap 'echo "{\"result\":\"rewritten\"}"; exit 0' TERM; sleep \#(nap)"#,
                                   timeout: 1, event: "AfterTool")
        defer { try? FileManager.default.removeItem(at: url) }
        let decision = await m.fireAfterTool(toolName: "t", result: "SECRET-unredacted")
        guard case .block(let reason) = decision else { Issue.record("a timed-out AfterTool hook did not block: \(decision)"); return }
        #expect(reason == "Hook timed out after 1 seconds")
        #expect(await P.gone("sleep \(nap)", within: 2), "sleep \(nap) outlived the timeout")
    }

    @Test("a timed-out hook on a warn-only event warns, and fireEvent keeps the original payload")
    func killedWarnOnlyHookKeepsPayload() async throws {
        let nap = P.marker()
        defer { P.killAll(nap) }
        let (m, url) = try manager(#"trap 'echo "{\"output\":\"rewritten\"}"; exit 0' TERM; sleep \#(nap)"#,
                                   timeout: 1, event: "AfterAgent", matcher: "AfterAgent")
        defer { try? FileManager.default.removeItem(at: url) }
        let decision = await m.fireAfterAgent(output: "original")
        guard case .proceed(let data?) = decision else { Issue.record("expected the turn to go on: \(decision)"); return }
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["output"] == "original")
    }

    @Test("a backgrounded grandchild holding the pipe does not hang the hook")
    func backgroundedGrandchild() async throws {
        let nap = P.marker()
        defer { P.killAll(nap) }
        let (m, url) = try manager(#"(sleep \#(nap) &); echo '{"ok":"1"}'"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let started = Date()
        let decision = await m.fireBeforeTool(toolName: "t", args: [:])
        let wall = Date().timeIntervalSince(started)
        guard case .proceed(let data?) = decision else { Issue.record("got \(decision)"); return }
        #expect(String(data: data, encoding: .utf8) == "{\"ok\":\"1\"}\n")
        #expect(wall < ProcessGroupRunner.strayGraceSeconds + 2, "returned after \(wall)s")
        #expect(await P.gone("sleep \(nap)", within: 3), "the pipe-holding sleep \(nap) was left running")
    }

    @Test("exit 2 still blocks with stderr as the reason, and stdout is still the new payload")
    func normalOutputUnchanged() async throws {
        let (block, u1) = try manager("echo nope >&2; exit 2")
        defer { try? FileManager.default.removeItem(at: u1) }
        guard case .block(let reason) = await block.fireBeforeTool(toolName: "t", args: [:]) else {
            Issue.record("expected block"); return
        }
        #expect(reason == "nope")

        let (pass, u2) = try manager(#"echo noise >&2; echo '{"a":"b"}'"#)
        defer { try? FileManager.default.removeItem(at: u2) }
        guard case .proceed(let data?) = await pass.fireBeforeTool(toolName: "t", args: [:]) else {
            Issue.record("expected proceed"); return
        }
        #expect(String(data: data, encoding: .utf8) == "{\"a\":\"b\"}\n")
    }

    @Test("a timed-out hook blocks, or warns on a warn-only event, whatever its status",
          arguments: [128 + SIGKILL, 0, 2, 1])
    func timedOutDecision(status: Int32) {
        let killed = ProcessGroupRunner.Output(stdout: Data("{}".utf8), stderr: Data(), status: status,
                                               timedOut: true, killed: true)
        guard case .block(let reason) = HookManager.decision(for: .success(killed), timeoutSeconds: 7, gating: true) else {
            Issue.record("expected block for status \(status)"); return
        }
        #expect(reason == "Hook timed out after 7 seconds")
        guard case .warning(let message) = HookManager.decision(for: .success(killed), timeoutSeconds: 7, gating: false) else {
            Issue.record("expected warning for status \(status)"); return
        }
        #expect(message == "Hook timed out after 7 seconds")
    }

    @Test("only events whose decision nothing acts on are warn-only; any other fails closed")
    func warnOnlyEvents() {
        #expect(HookManager.warnOnlyEvents == ["Notification", "SessionStart", "AfterAgent"])
    }

    @Test("a signal is not an exit code: a hook killed by SIGINT warns rather than blocks")
    func signalIsNotExitTwo() {
        // `Process.terminationStatus` reported the signal number, so SIGINT (2) read as a block.
        let killed = ProcessGroupRunner.Output(stdout: Data(), stderr: Data(), status: 128 + SIGINT)
        guard case .warning = HookManager.decision(for: .success(killed), timeoutSeconds: 60, gating: true) else {
            Issue.record("expected warning"); return
        }
    }
}

/// #364 and #368: `PluginAuthRunner.check` runs through `ProcessGroupRunner`. The old
/// `readabilityHandler` could append the output after the termination handler's snapshot, so a
/// signed-in check came back with no output; now the output is read only after the reap.
@Suite("Plugin auth check process group", .timeLimit(.minutes(1)))
struct PluginAuthRunnerProcessGroupTests {
    typealias P = RunCommandProcessGroupTests
    let allow: PluginAuthRunner.Approver = { _ in true }

    func auth(_ check: String) -> IPFManifest.AuthDeclaration {
        var a = try! YAMLAuthHelper.make(kind: "external")
        a.checkCommand = check
        return a
    }

    @Test("output past 64 KB comes back whole")
    func largeOutput() async {
        let status = await PluginAuthRunner.check(auth("head -c 300000 /dev/zero | tr '\\0' 'x'"),
                                                  config: [:], approve: allow)
        #expect(status.signedIn)
        #expect(status.output.count == 300_000)
    }

    @Test("stdout and stderr are still one stream")
    func mergedStreams() async {
        let status = await PluginAuthRunner.check(auth("echo a; echo b >&2; echo c"), config: [:], approve: allow)
        #expect(status.output == "a\nb\nc\n")
    }

    @Test("a check that ignores SIGTERM is killed within the grace after its timeout")
    func timeoutEscalatesToSigkill() async {
        let nap = P.marker()
        defer { P.killAll(nap) }
        let started = Date()
        let status = await PluginAuthRunner.check(auth("trap '' TERM; sleep \(nap); true"), config: [:],
                                                  approve: allow, timeoutSeconds: 1)
        let wall = Date().timeIntervalSince(started)
        #expect(!status.signedIn)
        #expect(wall < 1 + ProcessGroupRunner.terminateGraceSeconds + 2, "returned after \(wall)s")
        #expect(await P.gone("sleep \(nap)", within: 2), "sleep \(nap) outlived the SIGKILL")
    }

    /// #452: the test above flaked with `signedIn` true. Group SIGKILL is not atomic: `sleep` can
    /// die first, and the shell runs `true` and exits 0 before its own SIGKILL lands (1 in 4800
    /// under load, every time with a 5 ms gap between the two). That status is no answer from a
    /// check the timeout killed; this shell gives the same 0 on every run, through its trap.
    @Test("a check that exits 0 when its timeout kills it is not signed in")
    func killedCheckIsNotSignedIn() async {
        let nap = P.marker()
        defer { P.killAll(nap) }
        let status = await PluginAuthRunner.check(auth("trap 'exit 0' TERM; sleep \(nap)"), config: [:],
                                                  approve: allow, timeoutSeconds: 1)
        #expect(!status.signedIn, "a timed-out check read as signed in: \(status)")
        #expect(await P.gone("sleep \(nap)", within: 2), "sleep \(nap) outlived the timeout")
    }

    @Test("a backgrounded grandchild holding the pipe does not hang the check")
    func backgroundedGrandchild() async {
        let nap = P.marker()
        defer { P.killAll(nap) }
        let started = Date()
        let status = await PluginAuthRunner.check(auth("(sleep \(nap) &); echo ok"), config: [:], approve: allow)
        let wall = Date().timeIntervalSince(started)
        #expect(status.signedIn)
        #expect(status.output == "ok\n")
        #expect(wall < ProcessGroupRunner.strayGraceSeconds + 2, "returned after \(wall)s")
        #expect(await P.gone("sleep \(nap)", within: 3))
    }

    @Test("output written right before exit is never lost (#368)")
    func noOutputLostAtExit() async {
        let runs = 500
        let lost = await withTaskGroup(of: Int?.self) { group in
            var lost: [Int] = []
            var next = 0
            func add(_ i: Int) {
                group.addTask {
                    let s = await PluginAuthRunner.check(self.auth("printf 'tail-\(i)'"), config: [:], approve: self.allow)
                    return s.signedIn && s.output == "tail-\(i)" ? nil : i
                }
            }
            // 64 at a time: at 8 the old race never showed; at 64 it reproduced on old code.
            while next < min(64, runs) { add(next); next += 1 }
            for await result in group {
                if let result { lost.append(result) }
                if next < runs { add(next); next += 1 }
            }
            return lost
        }
        #expect(lost.isEmpty, "\(lost.count) of \(runs) checks lost their output: \(lost.prefix(10))")
    }
}

/// #364 review: a cancel kills the hook process, so its verdict never arrives. Before the fix, the
/// killed hook read as a warning, `fireEvent` treats a warning as proceed, and the tool ran: a
/// cancelled turn got past a `BeforeTool` hook that would have blocked it.
@MainActor
@Suite("Cancelled turn runs no gated tool", .timeLimit(.minutes(1)))
struct CancelledTurnHookTests {
    private func engine(hookCommand: String?, event: String = "BeforeTool", matcher: String = "write_file",
                        timeout: Int? = nil) throws -> (AppState, IrisEngine, UUID, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-cancel-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var hooks = HookManager()
        if let hookCommand {
            var hook: [String: Any] = ["type": "command", "command": hookCommand]
            if let timeout { hook["timeout"] = timeout }
            let config: [String: Any] = ["hooks": [event: [["matcher": matcher, "hooks": [hook]]]]]
            let url = dir.appendingPathComponent("settings.json")
            try JSONSerialization.data(withJSONObject: config).write(to: url)
            hooks.configPathOverride = url.path
        } else {
            hooks.configPathOverride = dir.appendingPathComponent("none.json").path
        }
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.permissions = PermissionManager(paths: IrisPaths(root: dir.appendingPathComponent("home")))
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0, hooks: hooks)
        let id = state.createNewConversation(title: "cancel")
        return (state, engine, id, dir)
    }

    private func write(_ target: URL, in dir: URL) -> BlockedCall {
        BlockedCall(toolName: "write_file", args: ["path": .string(target.path), "content": .string("x")], cwd: dir.path)
    }

    /// #452: a hung redaction hook fails closed. The tool's result is replaced by the blocked
    /// message, so the unredacted content never becomes the tool response the model reads.
    @Test("a timed-out AfterTool hook replaces the result, so the unredacted output never comes back")
    func timedOutAfterToolHookRedacts() async throws {
        let nap = RunCommandProcessGroupTests.marker()
        defer { RunCommandProcessGroupTests.killAll(nap) }
        let (_, engine, id, dir) = try engine(hookCommand: "trap 'exit 0' TERM; sleep \(nap)",
                                              event: "AfterTool", matcher: "read_file", timeout: 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appendingPathComponent("secret.txt")
        try "SECRET-\(UUID().uuidString)".write(to: secret, atomically: true, encoding: .utf8)
        let result = await engine.executeApprovedCall(
            BlockedCall(toolName: "read_file", args: ["path": .string(secret.path)], cwd: dir.path), conversationId: id)
        #expect(result == "System Hook blocked result: Hook timed out after 1 seconds", "\(result)")
        #expect(!result.contains("SECRET-"), "the unredacted result came back")
    }

    @Test("the harness's hook runs on the host and the write lands when nothing is cancelled")
    func control() async throws {
        let (_, engine, id, dir) = try engine(hookCommand: "sleep 1; exit 0")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("control.txt")
        let result = await engine.executeApprovedCall(write(target, in: dir), conversationId: id)
        #expect(result.hasPrefix("Successfully wrote to "), "\(result)")
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("a turn cancelled while a blocking BeforeTool hook decides does not run the tool")
    func cancelDuringBlockingHook() async throws {
        let (_, engine, id, dir) = try engine(hookCommand: "sleep 3; echo denied >&2; exit 2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("blocked.txt")
        let call = write(target, in: dir)
        let task = Task { await engine.executeApprovedCall(call, conversationId: id) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        let result = await task.value
        #expect(result.hasPrefix("System Hook blocked execution"), "\(result)")
        #expect(!FileManager.default.fileExists(atPath: target.path), "the cancelled write still landed")
    }

    @Test("a turn cancelled while a permissive hook runs does not run the tool either")
    func cancelDuringPermissiveHook() async throws {
        let (_, engine, id, dir) = try engine(hookCommand: "sleep 3; exit 0")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("permissive.txt")
        let call = write(target, in: dir)
        let task = Task { await engine.executeApprovedCall(call, conversationId: id) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        _ = await task.value
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("with no hook, a turn cancelled before dispatch writes nothing")
    func cancelBeforeDispatchNoHook() async throws {
        let (_, engine, id, dir) = try engine(hookCommand: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("nohook.txt")
        let call = write(target, in: dir)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.executeApprovedCall(call, conversationId: id)
        }
        let result = await task.value
        #expect(result == IrisEngine.cancelledToolResult("write_file"))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

/// #452 review: the warn-only list was pinned only as a constant. This drives a real turn: a
/// `PreCompress` hook may be redacting the history the provider is about to receive, so one its
/// timeout killed must stop the turn before any model call, not send the unredacted history.
@MainActor
@Suite("Timed-out PreCompress hook sends nothing", .timeLimit(.minutes(1)))
struct TimedOutPreCompressTests {
    @Test("a PreCompress hook that exits 0 when its timeout kills it stops the turn before any model call")
    func timedOutPreCompressMakesNoModelCall() async throws {
        let nap = RunCommandProcessGroupTests.marker()
        defer { RunCommandProcessGroupTests.killAll(nap) }
        let dir = try ThinkingFixtures.tempDirectory("precompress-timeout")
        defer { try? FileManager.default.removeItem(at: dir) }
        // The trap prints the history it was given, so a warn that kept going would still have
        // something to send; the hook's verdict never arrives either way.
        let hook: [String: Any] = ["type": "command", "timeout": 1,
                                   "command": "trap 'cat; exit 0' TERM; sleep \(nap)"]
        let settings = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["hooks": ["PreCompress": [["matcher": "PreCompress", "hooks": [hook]]]]])
            .write(to: settings)
        var hooks = HookManager()
        hooks.configPathOverride = settings.path

        let h = try ThinkingHarness.make([ThinkingFixtures.reply(1, toolCall: false)], hooks: hooks)
        await h.run("SECRET-\(nap) needs redacting")
        #expect(h.client.requests.isEmpty, "the turn sent \(h.client.requests.count) request(s) past a timed-out PreCompress hook")
        #expect(await RunCommandProcessGroupTests.gone("sleep \(nap)", within: 2), "sleep \(nap) outlived the timeout")
    }
}
