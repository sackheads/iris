import Foundation
import Testing
@testable import IrisKit

@Suite("AccessProfile: the user-configured grant, deny-all by default (#974 Task 2)")
struct AccessProfileTests {
    @Test("decoding an empty object yields deny-all on every axis, never .owner")
    func emptyDecodesToDenyAllNotOwner() throws {
        let data = Data("{}".utf8)
        let profile = try JSONDecoder().decode(AccessProfile.self, from: data)
        #expect(profile.credentials.isEmpty)
        #expect(profile.memoryRead == .none)
        #expect(profile.memoryWrite == .none)
        #expect(profile.transports.isEmpty)
        #expect(profile.fsRoots.isEmpty)
        #expect(profile.skills.isEmpty)
        #expect(profile.tools.isEmpty)
        #expect(profile != AccessProfile.owner)
    }

    @Test("MemoryTier is ordered task < shared < conversations < full")
    func memoryTierOrdering() {
        #expect(MemoryTier.task < MemoryTier.shared)
        #expect(MemoryTier.shared < MemoryTier.conversations)
        #expect(MemoryTier.conversations < MemoryTier.full)
        #expect(MemoryTier.none < MemoryTier.task)
    }

    @Test(".owner is full on every axis")
    func ownerIsFullOnEveryAxis() {
        let owner = AccessProfile.owner
        #expect(owner.memoryRead == .full)
        #expect(owner.memoryWrite == .full)
        // .owner is never decoded (a leaf constant), so it carries the sentinel "all" tools value
        // the dispatcher treats as unbounded only under .main — not a concrete finite set.
        #expect(owner.tools == .allTools)
    }

    @Test("round-trip Codable is stable for a non-trivial profile")
    func roundTripIsStable() throws {
        let original = AccessProfile(
            credentials: [AccountRef(type: "github", id: "iris-main")],
            memoryRead: .shared,
            memoryWrite: .task,
            transports: ["homelab-peer"],
            fsRoots: ["/tmp/work"],
            skills: ["web-researcher"],
            tools: .set(["search_memory", "read_file"])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AccessProfile.self, from: data)
        #expect(decoded == original)
    }
}
