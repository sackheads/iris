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
    private func manager(_ command: String, timeout: Int? = nil) throws -> (HookManager, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-hook-pg-\(UUID().uuidString).json")
        var hook: [String: Any] = ["type": "command", "command": command]
        if let timeout { hook["timeout"] = timeout }
        let config: [String: Any] = ["hooks": ["BeforeTool": [["matcher": "t", "hooks": [hook]]]]]
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
        // `fireEvent` treats a hook's warning as proceed, with the payload untouched.
        guard case .proceed = decision else { Issue.record("got \(decision)"); return }
        #expect(wall < 1 + ProcessGroupRunner.terminateGraceSeconds + 2, "returned after \(wall)s")
        #expect(await P.gone("sleep \(nap)", within: 2), "sleep \(nap) outlived the SIGKILL")
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

    @Test("a timed-out hook warns that it timed out")
    func timedOutWarning() {
        let killed = ProcessGroupRunner.Output(stdout: Data(), stderr: Data(), status: 128 + SIGKILL, timedOut: true)
        guard case .warning(let message) = HookManager.decision(for: .success(killed), timeoutSeconds: 7) else {
            Issue.record("expected warning"); return
        }
        #expect(message == "Hook timed out after 7 seconds")
    }

    @Test("a signal is not an exit code: a hook killed by SIGINT warns rather than blocks")
    func signalIsNotExitTwo() {
        // `Process.terminationStatus` reported the signal number, so SIGINT (2) read as a block.
        let killed = ProcessGroupRunner.Output(stdout: Data(), stderr: Data(), status: 128 + SIGINT)
        guard case .warning = HookManager.decision(for: .success(killed), timeoutSeconds: 60) else {
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
    private func engine(hookCommand: String?) throws -> (AppState, IrisEngine, UUID, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-cancel-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var hooks = HookManager()
        if let hookCommand {
            let config: [String: Any] = ["hooks": ["BeforeTool": [["matcher": "write_file",
                                         "hooks": [["type": "command", "command": hookCommand]]]]]]
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
