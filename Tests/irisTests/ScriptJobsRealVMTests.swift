import Testing
import Foundation
@testable import IrisKit

/// #330's four checks on a real VM, opt-in like `SandboxRealVMTests` (`IRIS_REAL_VM=1`, the
/// runtime started and `ubuntu:latest` local; nothing pulls). Every container is `iristest-330-…`
/// and the isolated network is `iristest-330-isolated`, both removed by the test that made them.
/// No curl in the image, so reachability is bash's `/dev/tcp`: "Connection refused" means a route
/// to the host, anything else (unreachable, a timeout) means none.
@Suite("Script jobs on a real VM", .enabled(if: RealContainer.isAvailable, "opt-in: IRIS_REAL_VM=1, with the container runtime started and \(RealContainer.image) local"),
       .timeLimit(.minutes(3)))
struct ScriptJobsRealVMTests {
    private static let network = "iristest-330-isolated"

    /// Short enough that `script-<uuid>` after it fits the runtime's 64 characters.
    static func prefix() -> String { "iristest-330-\(UUID().uuidString.prefix(4).lowercased())-" }

    /// The names of every container, running or not, starting with `prefix`.
    private func containers(_ prefix: String) -> [String] {
        let out = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RealContainer.binary)
        process.arguments = ["ls", "-a", "--format", "json"]
        process.standardOutput = out
        try? process.run()
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.components(separatedBy: "\"").filter { $0.hasPrefix(prefix) }
    }

    private func run(_ spec: ScriptSpec, prefix: String) async -> GateEvaluator.VMRun {
        await GateEvaluator.runScriptJob(spec, runtime: RealContainer.runtime(), image: RealContainer.image,
                                         namePrefix: prefix, isolatedNetwork: Self.network)
    }

    private func dropNetwork() {
        BlockingSpawn.run(RealContainer.binary, ["network", "delete", Self.network], timeoutSeconds: 60)
    }

    @Test("1: a script's last stdout line is the outcome, and its container is gone after")
    func outcome() async {
        let prefix = Self.prefix()
        defer { containers(prefix).forEach(RealContainer.delete); dropNetwork() }
        let result = await run(ScriptSpec(command: "echo first; echo '42% used'", mounts: [], timeoutSeconds: 60, network: false),
                               prefix: prefix)
        guard case .ran(let stdout, _, let exitCode) = result else { Issue.record("\(result)"); return }
        #expect(exitCode == 0)
        #expect(ScriptJobs.outcome(stdout: stdout, exitCode: exitCode) == "42% used")
        #expect(containers(prefix).isEmpty, "swept")
    }

    @Test("2: a script past its timeout is killed in the VM, and no container is left")
    func timeout() async {
        let prefix = Self.prefix()
        defer { containers(prefix).forEach(RealContainer.delete); dropNetwork() }
        let start = Date()
        let result = await run(ScriptSpec(command: "sleep 120", mounts: [], timeoutSeconds: 5, network: false), prefix: prefix)
        #expect(result == .timedOut(seconds: 5))
        #expect(Date().timeIntervalSince(start) < 90, "ended near its timeout, not the sleep's")
        #expect(containers(prefix).isEmpty, "nothing left running")
    }

    @Test("3: network off blocks the internet; the Mac is still reachable (#690, a known limit)")
    func networkOff() async {
        let prefix = Self.prefix()
        defer { containers(prefix).forEach(RealContainer.delete); dropNetwork() }
        let probe = """
            timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null && echo internet=REACHED || echo internet=BLOCKED
            gw=$(awk 'NR>1 && $2=="00000000" {print $3; exit}' /proc/net/route)
            ip=$(printf '%d.%d.%d.%d' 0x${gw:6:2} 0x${gw:4:2} 0x${gw:2:2} 0x${gw:0:2})
            out=$(timeout 5 bash -c "exec 3<>/dev/tcp/$ip/1" 2>&1)
            case "$out" in *refused*) echo host=REACHABLE ;; *) echo host=UNREACHABLE ;; esac
            """
        let result = await run(ScriptSpec(command: probe, mounts: [], timeoutSeconds: 60, network: false), prefix: prefix)
        guard case .ran(let stdout, _, _) = result else { Issue.record("\(result)"); return }
        #expect(stdout.contains("internet=BLOCKED"), "\(stdout)")
        // #690: "off" is host-only. A real no-network mode (#691) flips this on purpose.
        #expect(stdout.contains("host=REACHABLE"), "\(stdout)")
    }

    @Test("4: a read-only mount refuses a write, and the host folder is untouched")
    func readOnlyMount() async throws {
        let prefix = Self.prefix()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iristest-330-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            containers(prefix).forEach(RealContainer.delete)
            dropNetwork()
            try? FileManager.default.removeItem(at: dir)
        }
        let mount = GateEvaluator.readOnly([GateEvaluator.canonicalMount(dir.path + ":/in")])
        let result = await run(ScriptSpec(command: "touch /in/written", mounts: mount, timeoutSeconds: 60, network: false),
                               prefix: prefix)
        guard case .ran(_, _, let exitCode) = result else { Issue.record("\(result)"); return }
        #expect(exitCode != 0, "the write was refused")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
