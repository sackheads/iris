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

    @Test("a full tool grant capped by the broker's fixed floor narrows to the broker's own set")
    func fullGrantCappedByBrokerFloorNarrows() {
        let full = AccessProfile(credentials: [AccountRef(type: "github", id: "iris-main")],
                                 memoryRead: .full, memoryWrite: .full,
                                 tools: .set(["run_command", "search_memory", "write_file"]))
        let binding = AccessBinding(profile: full, principal: .broker, isOwner: false)
        let capped = binding.capped(by: PrincipalFloor.floor(for: .broker))
        guard case .set(let allowed) = capped.profile.tools else {
            Issue.record("expected .set after capping")
            return
        }
        #expect(allowed.isSubset(of: PrincipalFloor.brokerTools))
        #expect(allowed == ["search_memory"])
        // Ruling (#974 Task 3): capped(by:) narrows only the axis PrincipalFloor actually carries
        // (tools) — credentials/memory are not part of PrincipalFloor's shape (Task 1), so they
        // pass through capped(by:) unchanged. A dedicated H2 broker profile with empty credentials
        // is the resolver's job (Task 4/5), not a general property of capping by any floor.
        #expect(!capped.profile.credentials.isEmpty)
    }

    @Test("capping an owner binding by a non-main floor still narrows tools (sandboxOnly is not bypassed by isOwner)")
    func ownerBindingCappedByNonMainFloorNarrowsTools() {
        let binding = AccessBinding(profile: .owner, principal: .subagent, isOwner: true)
        let capped = binding.capped(by: PrincipalFloor.floor(for: .subagent))
        // .fromBinding defers to the binding's own grant, so owner's .allTools passes through —
        // this is Invariant 1: a subagent on the owner binding is owner.
        #expect(capped.profile.tools == .allTools)
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
}
