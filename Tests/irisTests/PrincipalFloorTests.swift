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

    @Test("broker and mcpGuest floors deny credentials and transports, and deny all memory writes")
    func brokerAndGuestFloorsDenyCredentialsTransportsAndWrites() {
        for principal: Principal in [.broker, .mcpGuest] {
            let floor = PrincipalFloor.floor(for: principal)
            #expect(floor.credentials == .fixed([]), "\(principal) should deny all credentials")
            #expect(floor.transports == .fixed([]), "\(principal) should deny all transports")
            #expect(floor.memoryWrite == .fixed(.none), "\(principal) should deny all memory writes")
        }
    }

    @Test("the broker's memory-read floor is the full owner-read ceiling (H2); the guest's is the least tier")
    func brokerReadsFullGuestReadsLeast() {
        #expect(PrincipalFloor.floor(for: .broker).memoryRead == .fixed(.full))
        #expect(PrincipalFloor.floor(for: .mcpGuest).memoryRead == .fixed(.task))
    }

    @Test("subagent and evaluator floors are fromBinding on every axis, not just tools")
    func subagentAndEvaluatorFloorsAreFromBindingOnEveryAxis() {
        for principal: Principal in [.subagent, .evaluator] {
            let floor = PrincipalFloor.floor(for: principal)
            #expect(floor.credentials == .fromBinding)
            #expect(floor.memoryRead == .fromBinding)
            #expect(floor.memoryWrite == .fromBinding)
            #expect(floor.transports == .fromBinding)
        }
    }

    @Test("main's floor is unbounded on every axis")
    func mainFloorIsUnboundedOnEveryAxis() {
        let floor = PrincipalFloor.floor(for: .main)
        #expect(floor.credentials == .unbounded)
        #expect(floor.memoryRead == .unbounded)
        #expect(floor.memoryWrite == .unbounded)
        #expect(floor.transports == .unbounded)
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

    /// #1203: the dispatcher's guest refusal is being rerouted from `GuestToolset.allowedNames.contains`
    /// onto `PrincipalFloor.isAllowed`. They are a no-op by construction today (the floor's `.fixed`
    /// set IS `GuestToolset.allowedNames`), but this pins the equivalence directly so a future edit to
    /// either one that silently diverges them is caught here, not discovered live.
    @Test("isAllowed under the mcpGuest floor agrees with GuestToolset.allowedNames for every tool name tried",
          arguments: ["send_to_session", "list_sessions", "run_command", "read_file", "write_file", "search_web",
                      "inbox_item", "describe_session", "invoke_subagent", "schedule_job",
                      "register_directory_watcher", "manage_fact", "search_memory", "search_conversations",
                      "read_conversation", "", "send_to_session "])
    func guestFloorAgreesWithGuestToolset(name: String) {
        let floor = PrincipalFloor.floor(for: .mcpGuest)
        #expect(PrincipalFloor.isAllowed(name, floor: floor, boundTools: []) == GuestToolset.allowedNames.contains(name))
    }
}
