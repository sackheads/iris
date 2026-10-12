import Testing
import Foundation
import Darwin
@testable import IrisKit

/// #463, the coordinator's ruling on #490: an exiting CLI deletes the containers it created, from
/// a lock-protected box (no actor hop), in parallel, each in a process group of its own, bounded
/// in all. A stub stands in for the `container` binary, run through `/bin/sh` so no freshly
/// written executable meets the first-exec check. Every test has its own box (invariant 7).
@Suite("LiveContainerNames (#463)", .timeLimit(.minutes(1)))
final class LiveContainerNamesTests {
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-463-names-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: base) }

    /// A `container` stand-in: logs `delete --force <name>`, its own pid and its process group,
    /// then `exec`s `sleep`, so the logged pid *is* the sleep and a kill at the bound leaves no orphan.
    private func stub(sleeping seconds: Double) throws -> (script: URL, log: URL) {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let log = base.appendingPathComponent("log-\(UUID().uuidString)")
        let script = base.appendingPathComponent("container-\(UUID().uuidString).sh")
        try """
        echo "$* pid=$$ pgid=$(ps -o pgid= -p $$ | tr -d ' ')" >> '\(log.path)'
        exec sleep \(seconds)
        """.write(to: script, atomically: true, encoding: .utf8)
        return (script, log)
    }

    private func lines(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test("names are recorded and dropped")
    func recordsAndDrops() {
        let live = LiveContainerNames()
        live.add("iris-a")
        live.add("iris-b")
        live.remove("iris-a")
        #expect(live.names == ["iris-b"])
    }

    @Test("every recorded container is deleted, in parallel, each in a process group of its own")
    func deletesInParallelInTheirOwnGroups() async throws {
        let live = LiveContainerNames()
        for name in ["iris-a", "iris-b", "iris-c"] { live.add(name) }
        let (script, log) = try stub(sleeping: 2)
        let started = Date()
        let task = Task.detached {
            live.deleteAll(within: 4) { name in ("/bin/sh", [script.path, "delete", "--force", name]) }
        }
        let finished = try await value(of: task, within: 15)
        #expect(finished == 3)
        // No bound under 5 s (CI is serial on 3 cores): three 2 s deletes in series take 6 s.
        #expect(Date().timeIntervalSince(started) < 5, "three 2 s deletes in parallel, not 6 s in series")
        let logged = lines(log)
        #expect(Set(logged.compactMap { $0.split(separator: " ").dropFirst(2).first.map(String.init) })
            == ["iris-a", "iris-b", "iris-c"])
        for line in logged {
            let fields = Dictionary(uniqueKeysWithValues: line.split(separator: " ").compactMap { part -> (String, String)? in
                let kv = part.split(separator: "=")
                return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
            })
            #expect(fields["pid"] == fields["pgid"], "SETPGROUP: a terminal's Ctrl-C cannot reach the delete: \(line)")
        }
        #expect(live.names.isEmpty, "a delete that succeeded drops its name")
    }

    @Test("a delete that hangs is cut off at the bound")
    func hungDeleteIsBounded() async throws {
        let live = LiveContainerNames()
        live.add("iris-stuck")
        let (script, log) = try stub(sleeping: 30)
        let started = Date()
        let task = Task.detached {
            live.deleteAll(within: 0.5) { name in ("/bin/sh", [script.path, "delete", "--force", name]) }
        }
        _ = try await value(of: task, within: 10)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(live.names == ["iris-stuck"], "not deleted, so still recorded")
        // The helper itself was SIGKILLed at the bound, not merely stopped being waited for.
        let pid = try #require(lines(log).first?.split(separator: " ").first { $0.hasPrefix("pid=") }
            .flatMap { Int32($0.dropFirst(4)) })
        var gone = false
        for _ in 0..<200 {
            if kill(pid, 0) == -1 && errno == ESRCH { gone = true; break }
            usleep(10_000)
        }
        #expect(gone, "BlockingSpawn's timeout killed and reaped the hung delete")
    }

    @Test("with nothing recorded, nothing is spawned")
    func nothingToDelete() {
        #expect(LiveContainerNames().deleteAll(within: 1) { _ in ("/usr/bin/false", []) } == 0)
    }

    @Test("the gate and one-off registries record their names in the box")
    func registriesRecord() async {
        let live = LiveContainerNames()
        let gates = GateContainerRegistry(live: live)
        let ephemeral = EphemeralContainerRegistry(live: live)
        await gates.register("iris-gate-x")
        await ephemeral.register("iris-hook-y")
        #expect(live.names == ["iris-gate-x", "iris-hook-y"])
        await gates.unregister("iris-gate-x")
        await ephemeral.unregister("iris-hook-y")
        #expect(live.names.isEmpty)
    }
}
