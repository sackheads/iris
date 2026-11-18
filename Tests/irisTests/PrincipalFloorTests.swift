import Testing
@testable import IrisKit

@Suite("PrincipalFloor: the non-negotiable per-Principal tool cap (#974 Task 1)")
struct PrincipalFloorTests {
    @Test("broker's floor is a fixed set with zero acting tools")
    func brokerFloorIsFixedReadOnly() {
        let floor = PrincipalFloor.floor(for: .broker)
        guard case .fixed(let tools) = floor.tools else {
            Issue.record("expected .fixed, got \(floor.tools)")
            return
        }
        #expect(tools == ["search_memory", "search_conversations", "read_conversation"])
        let actingTools: Set<String> = ["run_command", "write_file", "github_comment", "github_approve",
                                        "save_fact", "manage_fact", "update_memory", "update_soul"]
        #expect(tools.isDisjoint(with: actingTools))
    }

    @Test("main's floor is unbounded")
    func mainFloorIsUnbounded() {
        #expect(PrincipalFloor.floor(for: .main).tools == .unbounded)
    }

    @Test("mcpGuest's floor is fixed to GuestToolset.allowedNames")
    func mcpGuestFloorMatchesGuestToolset() {
        guard case .fixed(let tools) = PrincipalFloor.floor(for: .mcpGuest).tools else {
            Issue.record("expected .fixed")
            return
        }
        #expect(tools == GuestToolset.allowedNames)
    }

    @Test("subagent and evaluator floors resolve from the inherited binding, not a fixed list")
    func subagentAndEvaluatorFloorsAreFromBinding() {
        #expect(PrincipalFloor.floor(for: .subagent).tools == .fromBinding)
        #expect(PrincipalFloor.floor(for: .evaluator).tools == .fromBinding)
    }

    @Test("every non-main floor is sandbox-only and never foreground")
    func everyNonMainFloorIsSandboxOnly() {
        for principal: Principal in [.subagent, .evaluator, .mcpGuest, .broker] {
            let floor = PrincipalFloor.floor(for: principal)
            #expect(floor.sandboxOnly, "\(principal) floor should be sandboxOnly")
            #expect(!floor.foreground, "\(principal) floor should never be foreground")
        }
    }

    // MARK: - Effective-allowlist resolution (Step 4)

    @Test("unbounded allows any tool")
    func unboundedAllowsAnyTool() {
        let floor = PrincipalFloor.floor(for: .main)
        #expect(PrincipalFloor.isAllowed("anything_at_all", floor: floor, boundTools: []))
    }

    @Test("fixed allows only tools in its set — a broker call outside the set is refused")
    func fixedRefusesOutsideItsSet() {
        let floor = PrincipalFloor.floor(for: .broker)
        #expect(PrincipalFloor.isAllowed("search_memory", floor: floor, boundTools: []))
        #expect(!PrincipalFloor.isAllowed("run_command", floor: floor, boundTools: []))
        #expect(!PrincipalFloor.isAllowed("save_fact", floor: floor, boundTools: []))
    }

    @Test("fromBinding consults the bound tool grant, not a fixed list — a subagent call outside its narrow grant is refused")
    func fromBindingRefusesOutsideTheBoundGrant() {
        let floor = PrincipalFloor.floor(for: .subagent)
        let narrowGrant: Set<String> = ["read_file"]
        #expect(PrincipalFloor.isAllowed("read_file", floor: floor, boundTools: narrowGrant))
        #expect(!PrincipalFloor.isAllowed("run_command", floor: floor, boundTools: narrowGrant))
        // A tool absent from a narrower grant is refused even though it would be fine under a wider one.
        #expect(!PrincipalFloor.isAllowed("write_file", floor: floor, boundTools: narrowGrant))
    }
}
