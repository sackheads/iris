import Testing
import Foundation
import Darwin
@testable import IrisKit

/// #510 end to end, on the real runtime: a `--run-job` child with the CLI's own signal handling, a
/// mutating job whose scripted turn runs `sleep 90` in its session container, and real SIGINTs from
/// here. Its symptom was the session container left running and the lock still naming a dead pid,
/// so those are what is checked. Opt-in like `SandboxRealVMTests` (`IRIS_REAL_VM=1`).
///
/// The signals go to the child's pid, not its group: an exit test's child shares this process's
/// group. So the `container` clients it runs do not see them, which a terminal Ctrl-C would send
/// them too (#497).
@Suite("Exit-now on a real VM (#510)", .enabled(if: RealContainer.isAvailable, "opt-in: IRIS_REAL_VM=1, with the container runtime started and \(RealContainer.image) local"),
       .timeLimit(.minutes(3)), .serialized)
struct ExitNowRealVMTests {
    static func containerNames() -> Set<String> {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RealContainer.binary)
        process.arguments = ["list", "--all", "--quiet"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    struct Outcome: Sendable {
        var name: String?
        var signalled = 0
        var lastFoundNoProcess = false
    }

    /// Waits for the child's pid and its session's `sleep 90`, then sends `count` SIGINTs 0.2 s apart.
    static func drive(pidFile: URL, before: Set<String>, count: Int) async -> Outcome {
        var outcome = Outcome()
        var pid: pid_t = 0
        for _ in 0..<600 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let p = Int32(text), p > 0 { pid = p; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard pid > 0 else { return outcome }
        for _ in 0..<600 where outcome.name == nil {
            outcome.name = containerNames().subtracting(before).first { $0.hasPrefix("iris-") }
            if outcome.name == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard let name = outcome.name else { return outcome }
        for _ in 0..<300 where !RealContainer.runs("sleep 90", in: name) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        for i in 0..<count {
            if i > 0 { usleep(200_000) }
            let rc = kill(pid, SIGINT)
            outcome.signalled += 1
            outcome.lastFoundNoProcess = rc == -1 && errno == ESRCH
        }
        return outcome
    }

    static func lockIsVacated(_ lock: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: lock.path)[.size] as? Int) ?? -1) == 0
    }

    static func gone(_ name: String) async -> Bool {
        for _ in 0..<50 {
            if !containerNames().contains(name) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private struct Paths {
        let base: URL
        var pidFile: URL { base.appendingPathComponent("pid") }
        var lock: URL { base.appendingPathComponent("conversations.sqlite.lock") }
        var mount: URL { base.appendingPathComponent("nap") }
        init() throws {
            base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-510-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: base.appendingPathComponent("nap"), withIntermediateDirectories: true)
        }
    }

    /// Runs one child under `count` SIGINTs. The child is the real `--run-job` stop path: the CLI's
    /// `CLIStop` with its process-wide registries and real deletes, the real handlers, the lock.
    /// `deleted` is read before any leftover is cleaned up here.
    private func run(count: Int) async throws -> (status: ExitStatus?, outcome: Outcome, paths: Paths, deleted: Bool) {
        let paths = try Paths()
        let before = Self.containerNames()
        let driver = Task.detached { await Self.drive(pidFile: paths.pidFile, before: before, count: count) }
        let result = await #expect(processExitsWith: .failure) { [pid = paths.pidFile.path as String, lock = paths.lock.path as String, mount = paths.mount.path as String] in
            ConfigManager.shared.enableSandboxing = true
            ConfigManager.shared.sandboxImage = RealContainer.image
            let store = try! ConversationStore.inMemory()
            var job = Job(name: "nap510", prompt: "Nap.", trigger: .schedule(.interval(seconds: 60)), profile: .mutating)
            job.policy = JobPolicy(grants: JobGrant(mounts: [ContainerMount(source: mount)], network: true))
            try! store.ledger.upsert(job)
            let nap = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
                Part(functionCall: FunctionCall(name: "run_command", args: ["command": .string("sleep 90")]))]))],
                                     usageMetadata: nil)
            let done = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))],
                                      usageMetadata: nil)
            let lockURL = URL(fileURLWithPath: lock)
            let stop = CLIStop(vacate: { StoreLock.vacate(at: lockURL) })
            let signals = CLISignals.install { stop.receive($0) }
            guard signals.installed.contains(SIGINT) else { exit(5) }   // run `swift test` in the foreground
            try! Data("\(getpid())".utf8).write(to: URL(fileURLWithPath: pid))
            let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "nap510"), store: store,
                                           client: FakeLLMClient(responses: [nap, done]), lockPath: lockURL,
                                           protectionEnabled: false, stop: stop, out: { _ in }, err: { _ in })
            withExtendedLifetime(signals) {}
            stop.exit(code: code)
            while true { pause() }
        }
        let outcome = await driver.value
        var deleted = false
        if let name = outcome.name {
            deleted = await Self.gone(name)
            if !deleted { RealContainer.delete(name) }
        }
        return (result?.exitStatus, outcome, paths, deleted)
    }

    @Test("two SIGINTs: exit-now deletes the session container and vacates the lock, every time", arguments: 1...6)
    func twoSignals(_ attempt: Int) async throws {
        let (status, outcome, paths, deleted) = try await run(count: 2)
        defer { try? FileManager.default.removeItem(at: paths.base) }
        _ = try #require(outcome.name, "a session container was created")
        #expect(outcome.signalled == 2)
        #expect(status == .exitCode(130), "exit-now's own `_exit`, not death by SIGINT")
        #expect(deleted, "the session container was deleted")
        #expect(Self.lockIsVacated(paths.lock), "the lock's payload was emptied")
    }

    /// The issue's step 4b: a third SIGINT 0.2 s after the second. The third may end the CLI while
    /// the deletes run, which is the documented rule. What must never happen is the second ending
    /// it: then the third finds no process, and the cleanup has not run.
    @Test("three SIGINTs: the second never ends the CLI before its cleanup", arguments: 1...6)
    func threeSignals(_ attempt: Int) async throws {
        let (status, outcome, paths, deleted) = try await run(count: 3)
        defer { try? FileManager.default.removeItem(at: paths.base) }
        _ = try #require(outcome.name, "a session container was created")
        let vacated = Self.lockIsVacated(paths.lock)
        print("#510 three SIGINTs, attempt \(attempt): \(String(describing: status)), third found no process: \(outcome.lastFoundNoProcess), container deleted: \(deleted), lock vacated: \(vacated)")
        if status == .exitCode(130) {
            #expect(deleted && vacated, "a clean exit-now ran its cleanup")
        } else {
            #expect(status == .signal(SIGINT), "only the third SIGINT may end it outright")
            #expect(!outcome.lastFoundNoProcess, "it was alive when the third arrived")
        }
    }
}
