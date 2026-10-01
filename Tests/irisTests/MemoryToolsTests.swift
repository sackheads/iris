import Testing
import Foundation
@testable import iris

@Suite("Memory Tools Tests", .serialized)
struct MemoryToolsTests {

    /// Routed through `MemoryManagerPathsMutex` (5a Task 7, `TurnContextTests.swift`): `.serialized`
    /// only orders this suite's OWN tests against each other, not against `GuardedFileCacheTests` —
    /// a different suite — also swapping this same singleton's `.paths` concurrently. The restore
    /// happens before `release()`, not in a `defer` after it, so a contender can never start
    /// swapping `.paths` before this one's restore has landed.
    private func withTempPaths(_ body: (IrisPaths) -> Void) async {
        await MemoryManagerPathsMutex.shared.acquire()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-tools-\(UUID().uuidString)")
        let p = IrisPaths(root: root)
        try? p.ensureDirectories()
        let previous = MemoryManager.shared.paths
        MemoryManager.shared.paths = p
        body(p)
        MemoryManager.shared.paths = previous
        try? FileManager.default.removeItem(at: root)
        await MemoryManagerPathsMutex.shared.release()
    }

    @Test("updateSoul writes memory/SOUL.md")
    func testUpdateSoul() async {
        await withTempPaths { p in
            MemoryManager.shared.updateSoul(content: "new soul")
            #expect((try? String(contentsOf: p.soulMd, encoding: .utf8)) == "new soul")
        }
    }

    @Test("updateMemory writes memory/memory.md")
    func testUpdateMemory() async {
        await withTempPaths { p in
            MemoryManager.shared.updateMemory(content: "new memory")
            #expect((try? String(contentsOf: p.memoryMd, encoding: .utf8)) == "new memory")
        }
    }

    @Test("updateUserProfile writes memory/USER.md")
    func testUpdateUserProfile() async {
        await withTempPaths { p in
            MemoryManager.shared.updateUserProfile(content: "new user")
            #expect((try? String(contentsOf: p.userMd, encoding: .utf8)) == "new user")
        }
    }
}
