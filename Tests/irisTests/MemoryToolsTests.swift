import Testing
import Foundation
@testable import iris

/// 5a Task 7 fix round 1: these tests used to swap `MemoryManager.shared.paths` (a process-global
/// `var`, no synchronization) to isolate each test's content, which raced against any other test
/// doing the same — including the `MemoryManager(paths:)` injection seam's own tests in
/// `TurnContextTests.swift`. `MemoryManager(paths:)` removes the need for the swap entirely: each
/// test constructs its own manager over its own temp root, so `MemoryManager.shared` is never
/// touched here (invariant 7). No `.serialized` needed either — nothing is shared across tests.
@Suite("Memory Tools Tests")
struct MemoryToolsTests {

    private func withTempManager(_ body: (MemoryManager, IrisPaths) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = IrisPaths(root: root)
        let manager = MemoryManager(paths: p)
        body(manager, p)
    }

    @Test("updateSoul writes memory/SOUL.md")
    func testUpdateSoul() {
        withTempManager { manager, p in
            manager.updateSoul(content: "new soul")
            #expect((try? String(contentsOf: p.soulMd, encoding: .utf8)) == "new soul")
        }
    }

    @Test("updateMemory writes memory/memory.md")
    func testUpdateMemory() {
        withTempManager { manager, p in
            manager.updateMemory(content: "new memory")
            #expect((try? String(contentsOf: p.memoryMd, encoding: .utf8)) == "new memory")
        }
    }

    @Test("updateUserProfile writes memory/USER.md")
    func testUpdateUserProfile() {
        withTempManager { manager, p in
            manager.updateUserProfile(content: "new user")
            #expect((try? String(contentsOf: p.userMd, encoding: .utf8)) == "new user")
        }
    }
}
