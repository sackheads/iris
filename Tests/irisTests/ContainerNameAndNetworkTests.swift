import Testing
import Foundation
@testable import IrisKit

/// #698's real-VM run: three failures the stub tests never saw.
@Suite("Container names, the isolated network under concurrency, and the CLI's error", .timeLimit(.minutes(1)))
struct ContainerNameAndNetworkTests {

    @Test("every container name Iris builds fits the runtime's 64 characters, with either home's prefix")
    func namesFit() async {
        let prefixes = [IrisPaths.standard.root, IrisPaths.release.root].map(SandboxSessionManager.containerPrefix(for:))
        for prefix in prefixes {
            for kind in ["gate", "script", "hook", "run"] {
                let name = ContainerNames.make(prefix: prefix, kind: kind)
                #expect(name != nil && name!.count <= ContainerNames.maxLength, "\(prefix)\(kind)")
            }
            #expect((ContainerNames.make(prefix: prefix)?.count ?? 99) <= ContainerNames.maxLength, "session")
        }
        #expect(SandboxSessionManager.containerName(for: UUID()).count <= ContainerNames.maxLength)
        #expect(ContainerNames.make(prefix: ScriptJobsRealVMTests.prefix(), kind: "script") != nil, "the real-VM suite's")

        // The run that failed: `iristest-330-<8 hex>-script-<uuid>` is 65. Refused before any call.
        let long = "iristest-330-abcdef12-"
        #expect(ContainerNames.make(prefix: long, kind: "script") == nil)
        let launcher = RecordingLauncher()
        let run = await GateEvaluator.runInVM("true", mounts: [], timeoutSeconds: 5, network: true,
                                              runtime: CLIContainerRuntime(launch: launcher.launch), image: "ubuntu:latest",
                                              createCeiling: 60, kind: "script job", namePrefix: long)
        #expect(run == .failed(ContainerNames.tooLong(prefix: long, kind: "script")))
        #expect(launcher.callCount == 0)
    }

    /// A CLI where a second create while one is in flight fails with something that is not
    /// "already exists", and the listing shows a network only once its create has finished.
    final class RacyNetworkCLI: @unchecked Sendable {
        private let lock = NSLock()
        private let name: String
        private var exists = false
        private var creating = 0
        private(set) var creates = 0
        init(name: String) { self.name = name }
        var launch: CLIContainerRuntime.Launch {
            { [self] args, _, _ in
                if args.starts(with: ["network", "ls"]) {
                    return lock.withLock { (exists ? #"[{"id":"\#(name)"}]"# : "[]", "", 0) }
                }
                let first = lock.withLock { () -> Bool in creating += 1; creates += 1; return creating == 1 && !exists }
                defer { lock.withLock { creating -= 1 } }
                guard first else { return ("", "Error: XPC connection error: Connection interrupted", 1) }
                try await Task.sleep(nanoseconds: 100_000_000)
                lock.withLock { exists = true }
                return ("", "", 0)
            }
        }
    }

    @Test("eight concurrent callers set up one isolated network once, and none fails")
    func concurrentNetworkSetup() async throws {
        let name = "iristest-net-\(UUID().uuidString.prefix(8).lowercased())"
        let cli = RacyNetworkCLI(name: name)
        let runtime = CLIContainerRuntime(launch: cli.launch)
        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 { group.addTask { (try? await runtime.ensureIsolatedNetwork(named: name)) == nil } }
            var failed = 0
            for await f in group where f { failed += 1 }
            return failed
        }
        #expect(failures == 0)
        #expect(cli.creates == 1, "one create; every later caller found it listed")
    }

    @Test("a failed create reports the CLI's error line, not its progress lines")
    func createFailureKeepsTheError() async {
        let launcher = RecordingLauncher(result: ("[1/6] Fetching image\n[5/6] Unpacking init image",
                                                  "Error: container id length 65 exceeds maximum of 64 characters", 1))
        do {
            try await CLIContainerRuntime(launch: launcher.launch)
                .createDetached(name: "x", image: "ubuntu:latest", mounts: [], workdir: "/")
            Issue.record("expected a failure")
        } catch ContainerRuntimeError.createFailed(let message) {
            #expect(message.split(separator: "\n").first == "Error: container id length 65 exceeds maximum of 64 characters")
            #expect(!message.contains("Unpacking"))
        } catch { Issue.record("\(error)") }
        // No error line: the rest, still without progress. Only progress: kept whole, never empty.
        #expect(CLIContainerRuntime.failure(stdout: "[2/6] x", stderr: "unexpected") == "unexpected")
        #expect(CLIContainerRuntime.failure(stdout: "[2/6] x", stderr: "") == "[2/6] x")
    }
}
