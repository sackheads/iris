import Testing
import Foundation
import Darwin
@testable import IrisKit

/// The installed `container` runtime, for the few tests that can only be answered by a real VM.
/// Opt-in: they run only with `IRIS_REAL_VM=1`, so the default suite never depends on a booted
/// runtime or a local image (#374 was that dependency). Opted in, they are still skipped, not
/// failed, on a machine without the binary, the services started, or a local copy of the image
/// (nothing here pulls one).
///
/// Their containers are named `iristest-…`, which `SandboxSessionManager.namePrefix` (`iris-`) does
/// not match, so a running Iris never sweeps one, and each test deletes its own.
enum RealContainer {
    static let binary = "/usr/local/bin/container"
    static let image = "ubuntu:latest"

    static let isAvailable: Bool = {
        guard ProcessInfo.processInfo.environment["IRIS_REAL_VM"] == "1",
              FileManager.default.isExecutableFile(atPath: binary) else { return false }
        return BlockingSpawn.run(binary, ["system", "status"], timeoutSeconds: 15) == 0
            && BlockingSpawn.run(binary, ["image", "inspect", image], timeoutSeconds: 15) == 0
    }()

    static func uniqueName(_ issue: Int) -> String {
        "iristest-\(issue)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    static func delete(_ name: String) {
        BlockingSpawn.run(binary, ["delete", "--force", name], timeoutSeconds: 60)
    }

    /// The runtime exactly as the app builds it, but pinned to `binary`, which `isAvailable` vouched for.
    static func runtime() -> CLIContainerRuntime {
        CLIContainerRuntime(
            launch: { args, timeout, onKill in
                try await CLIProcessRunner(executable: binary).run(args, timeoutSeconds: timeout, onKill: onKill)
            },
            fire: { args, timeout in BlockingSpawn.detached(binary, args, timeoutSeconds: Double(timeout)) })
    }

    /// Whether a process whose argv starts with `pattern` is running in `name`. Plain syscalls and
    /// a child process, so it can be asked from a thread that is holding the pool.
    static func runs(_ pattern: String, in name: String) -> Bool {
        BlockingSpawn.run(binary, ["exec", name, "pgrep", "-f", pattern], timeoutSeconds: 15) == 0
    }
}

@Suite("Sandbox kills on a real VM", .enabled(if: RealContainer.isAvailable, "opt-in: IRIS_REAL_VM=1, with the container runtime started and \(RealContainer.image) local"),
       .timeLimit(.minutes(2)))
struct SandboxRealVMTests {

    /// #365: the session container's PID 1 was `sleep infinity`, which reaps nothing, so every
    /// timed-out command left its shell and its `sleep` behind as zombies for the life of the
    /// session. With `--init` the CLI's init is PID 1 and reaps them.
    @Test("a timed-out command leaves no zombie in the session container")
    func noZombiesAfterTimeout() async throws {
        let name = RealContainer.uniqueName(365)
        defer { RealContainer.delete(name) }
        let rt = RealContainer.runtime()
        try await rt.createDetached(name: name, image: RealContainer.image, mounts: [], workdir: "/")

        let nap = "30.\(Int.random(in: 100_000...999_999))"
        await #expect(throws: ContainerRuntimeError.self) {
            _ = try await rt.exec(name: name, workdir: "/", command: "sleep \(nap); true", timeoutSeconds: 1)
        }

        // The in-VM killer runs after the client's ladder and takes its own grace.
        var table = ""
        let deadline = Date().addingTimeInterval(20)
        repeat {
            table = (try? await rt.exec(name: name, workdir: "/", command: "ps -eo stat=,ppid=,args=", timeoutSeconds: 30).stdout) ?? ""
            let rows = table.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if !rows.contains(where: { $0.contains("sleep \(nap)") || $0.hasPrefix("Z") }) { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline

        let rows = table.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(!rows.isEmpty, "ps printed nothing")
        #expect(!rows.contains(where: { $0.contains("sleep \(nap)") }), "the command survived its timeout:\n\(table)")
        #expect(!rows.contains(where: { $0.hasPrefix("Z") }), "zombies in the VM:\n\(table)")
    }

    /// #365 review: `--init` puts the CLI's init between the container and the command's
    /// processes. An `exec`'s status must be unchanged by it: an exit code passes through, and a
    /// command killed by SIGTERM still reads as 143.
    @Test("exit codes pass through the session container's init")
    func exitCodesUnderInit() async throws {
        let name = RealContainer.uniqueName(365)
        defer { RealContainer.delete(name) }
        let rt = RealContainer.runtime()
        try await rt.createDetached(name: name, image: RealContainer.image, mounts: [], workdir: "/")
        let pid1 = try await rt.exec(name: name, workdir: "/", command: "cat /proc/1/cmdline | tr '\\0' ' '", timeoutSeconds: 30)
        #expect(pid1.stdout.contains("init"), "PID 1 is not the CLI's init: \(pid1.stdout)")
        let seven = try await rt.exec(name: name, workdir: "/", command: "echo out; exit 7", timeoutSeconds: 30)
        #expect(seven.exitCode == 7)
        #expect(seven.stdout == "out\n")
        let term = try await rt.exec(name: name, workdir: "/", command: "kill -TERM $$", timeoutSeconds: 30)
        #expect(term.exitCode == 143)
        let termChild = try await rt.exec(name: name, workdir: "/", command: "sleep 30 & p=$!; kill -TERM $p; wait $p", timeoutSeconds: 30)
        #expect(termChild.exitCode == 143)
    }

    /// #377: with every pool thread held, the in-VM group killer still fires on time. It used to
    /// start in a `Task` after `exec` threw, so it waited for the pool while the command ran on in
    /// the VM. Run in an exit-test child, like `KillEscalationPoolStarvationTests`, so the hold
    /// cannot stall other suites.
    @Test("a timed-out command in the VM is killed while the cooperative pool is held")
    func inVMKillUnderStarvation() async {
        await #expect(processExitsWith: .success) {
            await VMStarvation.timeoutKillsInVM()
        }
    }
}

/// Runs inside the exit-test child, and exits it: 0 when the command was gone from the VM in time,
/// 1 when it was not, 2 when the pool could not be held, 4 when the container could not be made.
enum VMStarvation {
    /// Long enough to see the command start in the VM and then take the pool before it fires.
    static let timeout = 6

    static func timeoutKillsInVM() async {
        let name = RealContainer.uniqueName(377)
        let rt = RealContainer.runtime()
        do {
            try await rt.createDetached(name: name, image: RealContainer.image, mounts: [], workdir: "/")
        } catch {
            finish(4, name, "create failed: \(error)")
        }
        let nap = "30.\(Int.random(in: 100_000...999_999))"
        let started = Date()
        let call = Task.detached {
            try await rt.exec(name: name, workdir: "/", command: "sleep \(nap); true", timeoutSeconds: timeout)
        }
        let appeared = Date().addingTimeInterval(Double(timeout) - 3)
        while !RealContainer.runs("^sleep \(nap)", in: name), Date() < appeared { usleep(100_000) }
        guard RealContainer.runs("^sleep \(nap)", in: name) else { finish(1, name, "the command never started in the VM") }

        let hold = PoolHold()
        hold.engage()
        guard hold.isHeld() else {
            hold.release()
            finish(2, name, "could not hold the cooperative pool")
        }
        guard Date() < started.addingTimeInterval(Double(timeout)) else {
            hold.release()
            finish(2, name, "the pool was taken only after the deadline; the scenario proves nothing")
        }
        // The deadline, the client's ladder, then the killer's own `container exec` and grace.
        let until = started.addingTimeInterval(Double(timeout) + CLIProcessRunner.killGraceSeconds + 6)
        while RealContainer.runs("^sleep \(nap)", in: name), Date() < until { usleep(250_000) }
        let survived = RealContainer.runs("^sleep \(nap)", in: name)
        hold.release()
        _ = call
        finish(survived ? 1 : 0, name, survived ? "sleep \(nap) outlived its kill deadline in the VM with the pool held" : "")
    }

    private static func finish(_ code: Int32, _ name: String, _ message: String) -> Never {
        RealContainer.delete(name)
        if !message.isEmpty { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        exit(code)
    }
}
