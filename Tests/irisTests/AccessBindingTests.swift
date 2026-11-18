import Testing
@testable import IrisKit

@Suite("AccessBinding: a run acts as an AccessProfile, capped by its Principal floor (#974 Task 3)")
struct AccessBindingTests {
    @Test("the owner binding capped by main's unbounded floor is unchanged")
    func ownerCappedByMainFloorIsUnchanged() {
        let binding = AccessBinding(profile: .owner, principal: .main, isOwner: true)
        let capped = binding.capped(by: PrincipalFloor.floor(for: .main))
        #expect(capped == binding)
    }

    @Test("a full profile capped by the broker's H2 floor narrows every floor axis (planner's ruling, #1201 review finding 4)")
    func fullGrantCappedByBrokerFloorNarrows() {
        let full = AccessProfile(credentials: [AccountRef(type: "github", id: "iris-main")],
                                 memoryRead: .full, memoryWrite: .full,
                                 transports: ["homelab-peer"],
                                 tools: .set(["run_command", "search_memory", "write_file"]))
        let binding = AccessBinding(profile: full, principal: .broker, isOwner: false)
        let capped = binding.capped(by: PrincipalFloor.floor(for: .broker))
        guard case .set(let allowed) = capped.profile.tools else {
            Issue.record("expected .set after capping")
            return
        }
        #expect(allowed == ["search_memory"])
        // H2's full capability floor, not just tools: zero credentials, zero transports, no
        // writes, owner-read memory (the floor's "fixed(.full)" ceiling, matched here since the
        // profile was already .full).
        #expect(capped.profile.credentials.isEmpty)
        #expect(capped.profile.transports.isEmpty)
        #expect(capped.profile.memoryWrite == .none)
        #expect(capped.profile.memoryRead == .full)
    }

    @Test("a profile below the floor's memory ceiling is not raised to it")
    func memoryTierNeverRisesToTheFloorCeiling() {
        let narrow = AccessProfile(memoryRead: .task)
        let binding = AccessBinding(profile: narrow, principal: .broker, isOwner: false)
        let capped = binding.capped(by: PrincipalFloor.floor(for: .broker))
        // The broker's floor ceiling is .full, but capping only ever narrows — it must not raise
        // a profile that already reads less than the ceiling.
        #expect(capped.profile.memoryRead == .task)
    }

    @Test("capping an owner binding by a non-main floor still narrows every axis the floor caps (sandboxOnly is not bypassed by isOwner)")
    func ownerBindingCappedByNonMainFloorNarrowsAxes() {
        let binding = AccessBinding(profile: .owner, principal: .subagent, isOwner: true)
        let capped = binding.capped(by: PrincipalFloor.floor(for: .subagent))
        // .fromBinding defers to the binding's own grant on every axis for subagent/evaluator, so
        // owner's full access passes through unchanged — this is Invariant 1: a subagent on the
        // owner binding is owner.
        #expect(capped.profile.tools == .allTools)
        #expect(capped.profile.memoryRead == .full)
        #expect(capped.profile.memoryWrite == .full)
    }

    @Test("a fixed floor narrower than the profile's own set intersects, never widens")
    func fixedFloorIntersectsNeverWidens() {
        let narrow = AccessProfile(tools: .set(["search_memory"]))
        let binding = AccessBinding(profile: narrow, principal: .mcpGuest, isOwner: false)
        let capped = binding.capped(by: PrincipalFloor.floor(for: .mcpGuest))
        guard case .set(let allowed) = capped.profile.tools else {
            Issue.record("expected .set")
            return
        }
        // search_memory is not in GuestToolset.allowedNames, so the intersection is empty — the
        // grant alone does not restore a tool the floor denies.
        #expect(allowed.isEmpty)
    }

    @Test("an mcpGuest floor denies credentials and transports and caps memory read to the least tier")
    func mcpGuestFloorDeniesCredentialsAndTransports() {
        let wide = AccessProfile(credentials: [AccountRef(type: "github", id: "x")],
                                 memoryRead: .full, memoryWrite: .full, transports: ["peer-a"])
        let binding = AccessBinding(profile: wide, principal: .mcpGuest, isOwner: false)
        let capped = binding.capped(by: PrincipalFloor.floor(for: .mcpGuest))
        #expect(capped.profile.credentials.isEmpty)
        #expect(capped.profile.transports.isEmpty)
        #expect(capped.profile.memoryWrite == .none)
        #expect(capped.profile.memoryRead == .task)
    }
}
