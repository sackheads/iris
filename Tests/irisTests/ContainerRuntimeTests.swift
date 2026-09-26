import Testing
import Foundation
@testable import iris

/// Records the argv of every `container` invocation, so a test can assert exactly what a call
/// renders without a `container` binary, a daemon, or a VM anywhere near it (invariant 7).
final class RecordingLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(args: [String], timeout: Int?)] = []
    private var scripted: (stdout: String, stderr: String, exitCode: Int32) = ("", "", 0)
    private var queue: [(stdout: String, stderr: String, exitCode: Int32)] = []

    init(result: (stdout: String, stderr: String, exitCode: Int32) = ("", "", 0)) {
        self.scripted = result
    }

    /// One result per call, in order; the last repeats once the queue is spent.
    init(results: [(stdout: String, stderr: String, exitCode: Int32)]) {
        self.queue = results
        self.scripted = results.last ?? ("", "", 0)
    }

    var launch: CLIContainerRuntime.Launch {
        { [self] args, timeout in
            lock.withLock {
                calls.append((args, timeout))
                if queue.count > 1 { return queue.removeFirst() }
                return queue.first ?? scripted
            }
        }
    }

    var argv: [[String]] { lock.withLock { calls.map(\.args) } }
    var timeouts: [Int?] { lock.withLock { calls.map(\.timeout) } }
    var callCount: Int { lock.withLock { calls.count } }
    var lastArgv: [String] { lock.withLock { calls.last?.args ?? [] } }
}

@Suite("ContainerRuntime argv")
struct ContainerRuntimeTests {
    /// Every value that follows a `--mount` flag, in order.
    private func mountValues(_ argv: [String]) -> [String] {
        argv.indices.compactMap { i in argv[i] == "--mount" && i + 1 < argv.count ? argv[i + 1] : nil }
    }

    @Test("createDetached renders one --mount per entry, in order")
    func mountPerEntry() async throws {
        let launcher = RecordingLauncher()
        let rt = CLIContainerRuntime(launch: launcher.launch)
        try await rt.createDetached(name: "iris-a", image: "ubuntu:latest",
                                    mounts: ["/ws:/ws", "/data:/mnt/data:ro"], workdir: "/ws")
        #expect(mountValues(launcher.lastArgv) == [
            "type=virtiofs,source=/ws,target=/ws",
            "type=virtiofs,source=/data,target=/mnt/data,readonly",
        ])
        #expect(launcher.lastArgv.prefix(4) == ["run", "-d", "--name", "iris-a"])
        #expect(launcher.lastArgv.suffix(5) == ["-w", "/ws", "ubuntu:latest", "sleep", "infinity"])
    }

    @Test("a bare path mounts at the same path inside the container")
    func bareEntry() async throws {
        let launcher = RecordingLauncher()
        try await CLIContainerRuntime(launch: launcher.launch)
            .createDetached(name: "iris-b", image: "img", mounts: ["/ws"], workdir: "/ws")
        #expect(mountValues(launcher.lastArgv) == ["type=virtiofs,source=/ws,target=/ws"])
    }

    @Test("an empty mount list renders no --mount at all")
    func noMounts() async throws {
        let launcher = RecordingLauncher()
        try await CLIContainerRuntime(launch: launcher.launch)
            .createDetached(name: "iris-c", image: "img", mounts: [], workdir: "/")
        #expect(!launcher.lastArgv.contains("--mount"))
        #expect(launcher.lastArgv == ["run", "-d", "--name", "iris-c", "-w", "/", "img", "sleep", "infinity"])
    }

    /// A path with a space is safe: each mount is one argv element handed to `Process`, which
    /// execs the binary directly. Nothing goes through a shell, so nothing word-splits it.
    @Test("a path containing a space is passed through unchanged, in one argv element")
    func spaceInPath() async throws {
        let launcher = RecordingLauncher()
        try await CLIContainerRuntime(launch: launcher.launch)
            .createDetached(name: "iris-d", image: "img",
                            mounts: ["/Users/me/My Notes:/work/My Notes"], workdir: "/work/My Notes")
        #expect(mountValues(launcher.lastArgv) == ["type=virtiofs,source=/Users/me/My Notes,target=/work/My Notes"])
        #expect(launcher.lastArgv.contains("/work/My Notes"))
    }

    @Test("a granted job's create argv: mounts in order, then --network iris-isolated --no-dns, then -w")
    func grantedCreateArgv() async throws {
        let launcher = RecordingLauncher()
        try await CLIContainerRuntime(launch: launcher.launch).createDetached(
            name: "iris-g", image: "img",
            mounts: ["/Users/me/proj", "/Users/me/deploy-key:ro"], workdir: "/Users/me/proj",
            network: .isolated)
        #expect(launcher.lastArgv == [
            "run", "-d", "--name", "iris-g",
            "--mount", "type=virtiofs,source=/Users/me/proj,target=/Users/me/proj",
            "--mount", "type=virtiofs,source=/Users/me/deploy-key,target=/Users/me/deploy-key,readonly",
            "--network", "iris-isolated", "--no-dns",
            "-w", "/Users/me/proj", "img", "sleep", "infinity",
        ])
    }

    @Test("network on is the default network: no --network, no --no-dns; the four-argument form is the same")
    func defaultNetworkArgv() async throws {
        let launcher = RecordingLauncher()
        let rt = CLIContainerRuntime(launch: launcher.launch)
        try await rt.createDetached(name: "iris-n", image: "img", mounts: ["/p"], workdir: "/p", network: .default)
        #expect(!launcher.lastArgv.contains("--network") && !launcher.lastArgv.contains("--no-dns"))
        try await rt.createDetached(name: "iris-n", image: "img", mounts: ["/p"], workdir: "/p")
        #expect(launcher.argv[0] == launcher.argv[1])
    }

    /// The shape `container network ls --format json` prints (measured 2026-09-23, CLI 1.1.0).
    private static let listWithDefaultOnly = #"[{"id":"default","configuration":{"name":"default","mode":"nat"}}]"#
    private static let listWithIsolated = #"[{"id":"default","configuration":{"name":"default"}},{"id":"iris-isolated","configuration":{"name":"iris-isolated"}}]"#

    @Test("ensureIsolatedNetwork lists, creates once when absent, and never creates when present under either key")
    func ensureIsolatedNetworkCreatesOnce() async throws {
        let absent = RecordingLauncher(result: (Self.listWithDefaultOnly, "", 0))
        try await CLIContainerRuntime(launch: absent.launch).ensureIsolatedNetwork(named: "iris-isolated")
        #expect(absent.argv == [["network", "ls", "--format", "json"],
                                ["network", "create", "--internal", "iris-isolated"]])
        #expect(absent.timeouts.allSatisfy { $0 == CLIContainerRuntime.housekeepingTimeoutSeconds })

        let present = RecordingLauncher(result: (Self.listWithIsolated, "", 0))
        try await CLIContainerRuntime(launch: present.launch).ensureIsolatedNetwork(named: "iris-isolated")
        #expect(present.argv == [["network", "ls", "--format", "json"]])

        // Only `configuration.name` carries it (a CLI that drops the top-level id): still found.
        let byName = RecordingLauncher(result: (#"[{"configuration":{"name":"iris-isolated"}}]"#, "", 0))
        try await CLIContainerRuntime(launch: byName.launch).ensureIsolatedNetwork(named: "iris-isolated")
        #expect(byName.argv.count == 1)
    }

    @Test("a create that loses a race is success; any other failed create, or a failed listing, is networkFailed")
    func ensureIsolatedNetworkRaceAndFailure() async {
        // Per-call scripting: the listing says the network is absent, then the create loses the
        // race — exit 1 with the CLI's "already exists" on stderr — which is success.
        let raced = RecordingLauncher(results: [(Self.listWithDefaultOnly, "", 0),
                                                ("", "Error: network iris-isolated already exists", 1)])
        await #expect(throws: Never.self) {
            try await CLIContainerRuntime(launch: raced.launch).ensureIsolatedNetwork(named: "iris-isolated")
        }
        #expect(raced.argv.count == 2)

        let denied = RecordingLauncher(results: [(Self.listWithDefaultOnly, "", 0), ("", "Error: permission denied", 1)])
        await #expect(throws: ContainerRuntimeError.networkFailed("Error: permission denied")) {
            try await CLIContainerRuntime(launch: denied.launch).ensureIsolatedNetwork(named: "iris-isolated")
        }

        // A listing that fails is a network nobody can vouch for: no create is attempted.
        let unlisted = RecordingLauncher(results: [("", "boom", 1)])
        await #expect(throws: ContainerRuntimeError.networkFailed("boom")) {
            try await CLIContainerRuntime(launch: unlisted.launch).ensureIsolatedNetwork(named: "iris-isolated")
        }
        #expect(unlisted.argv == [["network", "ls", "--format", "json"]])
    }

    /// A path with a comma is refused, because `container --mount` takes a comma-separated
    /// `key=value` list and offers no escape: the comma would start a new key.
    @Test("a path containing a comma is refused, and nothing is launched")
    func commaInPathRejected() async {
        let launcher = RecordingLauncher()
        let rt = CLIContainerRuntime(launch: launcher.launch)
        await #expect(throws: ContainerRuntimeError.self) {
            try await rt.createDetached(name: "iris-e", image: "img",
                                        mounts: ["/Users/me/a,b:/work"], workdir: "/work")
        }
        #expect(launcher.callCount == 0)
    }

    @Test("a mount entry that is not source[:target][:ro] is refused")
    func malformedEntryRejected() {
        #expect(throws: ContainerRuntimeError.self) { try ContainerMount.argument(for: "") }
        #expect(throws: ContainerRuntimeError.self) { try ContainerMount.argument(for: "/a:/b:/c") }
        #expect(throws: ContainerRuntimeError.self) { try ContainerMount.argument(for: "/a:") }
        #expect(throws: ContainerRuntimeError.self) { try ContainerMount.argument(for: "/a:/b:rw") }
    }

    /// L2: the CLI reads a source that is not an absolute path as a *named volume*, not a bind,
    /// so `data:/data:ro` would quietly look up a volume instead of mounting the directory.
    @Test("a source that is not an absolute path is refused")
    func relativeSourceRejected() {
        #expect(throws: ContainerRuntimeError.self) { try ContainerMount.argument(for: "data:/data:ro") }
        #expect(throws: ContainerRuntimeError.self) { try ContainerMount.argument(for: "/data:data") }
        #expect(throws: ContainerRuntimeError.self) { try ContainerMount.argument(for: "~/data:/data") }
    }

    /// L10: the CLI splits a directive at the *first* `=` and takes the rest of the value
    /// verbatim, so an `=` in a path is safe — and refusing it would lose a mount that worked
    /// before this task.
    @Test("a path containing an equals sign is passed through")
    func equalsInPathAllowed() throws {
        #expect(try ContainerMount.argument(for: "/a=b:/work") == "type=virtiofs,source=/a=b,target=/work")
        #expect(try ContainerMount.argument(for: "/a:/work=x") == "type=virtiofs,source=/a,target=/work=x")
    }

    @Test("a read-only entry with no explicit target mounts the source at itself")
    func readOnlySameTarget() throws {
        #expect(try ContainerMount.argument(for: "/ws:ro") == "type=virtiofs,source=/ws,target=/ws,readonly")
    }

    @Test("exec renders the exec argv and hands the per-command timeout to the launcher")
    func execForwardsTimeout() async throws {
        let launcher = RecordingLauncher(result: ("hi", "", 0))
        let rt = CLIContainerRuntime(launch: launcher.launch)
        let r = try await rt.exec(name: "iris-f", workdir: "/ws", command: "echo hi", timeoutSeconds: 45)
        #expect(r.stdout == "hi")
        #expect(launcher.lastArgv == ["exec", "-w", "/ws", "iris-f", "bash", "-c", "echo hi"])
        #expect(launcher.timeouts == [45])
    }

    @Test("exec with no timeout passes none")
    func execNoTimeout() async throws {
        let launcher = RecordingLauncher()
        _ = try await CLIContainerRuntime(launch: launcher.launch)
            .exec(name: "iris-g", workdir: "/", command: "true", timeoutSeconds: nil)
        #expect(launcher.timeouts == [nil])
    }

    /// R27: the calls that are not the user's command are bounded, so `reapOrphans()` on the
    /// launch path cannot be the thing that never comes back. R31: a create is bounded too, far
    /// more loosely — a cold image pull is legitimately minutes — but bounded.
    @Test("housekeeping calls carry a deadline, and so does a create")
    func housekeepingDeadlines() async throws {
        let launcher = RecordingLauncher(result: ("[]", "", 0))
        let rt = CLIContainerRuntime(launch: launcher.launch)
        await rt.remove(name: "iris-a")
        _ = await rt.list(prefix: "iris-")
        #expect(launcher.timeouts == [60, 60, 60])
        #expect(launcher.argv.map(\.first) == ["stop", "delete", "list"])

        let creator = RecordingLauncher()
        try await CLIContainerRuntime(launch: creator.launch)
            .createDetached(name: "iris-a", image: "img", mounts: [], workdir: "/")
        #expect(creator.timeouts == [CLIContainerRuntime.createTimeoutSeconds])
        #expect(CLIContainerRuntime.createTimeoutSeconds == 1_200, "twenty minutes, per R31")
    }

    @Test("a non-zero create exit becomes createFailed carrying the CLI's output")
    func createFailure() async {
        let launcher = RecordingLauncher(result: ("", "no such image\n", 1))
        let rt = CLIContainerRuntime(launch: launcher.launch)
        await #expect(throws: ContainerRuntimeError.createFailed("no such image")) {
            try await rt.createDetached(name: "iris-h", image: "nope", mounts: [], workdir: "/")
        }
    }
}
