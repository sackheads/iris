import Foundation
import os

/// #463, the coordinator's ruling on #490: the containers this process created and has not
/// removed — its sessions, gate containers and one-offs — for a CLI that is exiting, after a
/// clean stop or at once on a second signal.
///
/// A lock-protected set, not an actor: the signal path reads it synchronously, with no hop onto a
/// cooperative pool that may be starved (#372). It names only what this process made, never a
/// sweep by `SandboxSessionManager.namePrefix`, which `~/.iris` and `~/.iris-dev` share.
final class LiveContainerNames: @unchecked Sendable {
    static let shared = LiveContainerNames()

    private let lock = NSLock()
    private var set: Set<String> = []

    func add(_ name: String) { lock.withLock { _ = set.insert(name) } }
    func remove(_ name: String) { lock.withLock { _ = set.remove(name) } }
    var names: Set<String> { lock.withLock { set } }

    /// Deletes every recorded container in parallel, each through `BlockingSpawn` in a process
    /// group of its own, and returns within `seconds` (plus a moment) whatever they are doing: a
    /// helper still running at the bound is SIGKILLed by `BlockingSpawn`. A delete that exits 0
    /// drops its name. Returns how many exited 0 by the time it returns. `command` is a seam for
    /// the `container` binary; nil means the installed one, and none installed means nothing to do.
    /// Blocks its caller: call it from a signal source's queue or the exit path, never the pool.
    @discardableResult
    func deleteAll(within seconds: TimeInterval,
                   command: ((String) -> (path: String, arguments: [String]))? = nil) -> Int {
        let targets = names
        guard !targets.isEmpty else { return 0 }
        let build: (String) -> (path: String, arguments: [String])
        if let command {
            build = command
        } else if let binary = SandboxingManager.resolveBinaryPath() {
            build = { (binary, ["delete", "--force", $0]) }
        } else {
            return 0
        }
        let group = DispatchGroup()
        let deleted = OSAllocatedUnfairLock(initialState: 0)
        for name in targets {
            let (path, arguments) = build(name)
            group.enter()
            BlockingSpawn.detached(path, arguments, timeoutSeconds: seconds, newGroup: true) { status in
                if status == 0 {
                    self.remove(name)
                    deleted.withLock { $0 += 1 }
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + seconds + 0.5)
        return deleted.withLock { $0 }
    }
}
