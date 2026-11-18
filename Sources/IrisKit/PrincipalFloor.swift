import Foundation

/// The positive-allowlist shape of a Principal's tool cap (#974 Task 1). `.fixed` names the exact
/// set up front (a guest or the disclosure broker); `.fromBinding` defers to the run's own
/// `AccessProfile.tools` grant (Task 2) because a subagent/evaluator does arbitrary *bounded* work,
/// not a fixed shape of it.
public enum ToolCap: Equatable, Sendable {
    case unbounded
    case fixed(Set<String>)
    case fromBinding
}

/// The non-negotiable per-Principal cap (spec "the fixed code floor"): a cap, never a grant. Every
/// non-`.main` floor is sandbox-only and never foreground.
public struct PrincipalFloor: Equatable, Sendable {
    public let tools: ToolCap
    public let sandboxOnly: Bool
    public let foreground: Bool
}

public extension PrincipalFloor {
    /// The disclosure broker's floor (spec H2): owner-memory read only, zero acting tools. Exactly
    /// the three read-only memory tools — no writer, no `run_command`, no credential proxy.
    static let brokerTools: Set<String> = ["search_memory", "search_conversations", "read_conversation"]

    static func floor(for principal: Principal) -> PrincipalFloor {
        switch principal {
        case .main:
            return PrincipalFloor(tools: .unbounded, sandboxOnly: false, foreground: true)
        case .mcpGuest:
            return PrincipalFloor(tools: .fixed(GuestToolset.allowedNames), sandboxOnly: true, foreground: false)
        case .broker:
            return PrincipalFloor(tools: .fixed(brokerTools), sandboxOnly: true, foreground: false)
        case .subagent, .evaluator:
            // Arbitrary bounded work: the positive allowlist is the inherited Binding's own tool
            // grant (Task 2's `AccessProfile.tools`), not a fixed Principal list.
            return PrincipalFloor(tools: .fromBinding, sandboxOnly: true, foreground: false)
        }
    }

    /// The effective-allowlist resolution the dispatcher consults: `.fixed` checks its own set,
    /// `.fromBinding` checks the run's bound tool grant (ignored otherwise), `.unbounded` allows
    /// anything. A tool outside the effective set is refused regardless of which Principal asked.
    static func isAllowed(_ toolName: String, floor: PrincipalFloor, boundTools: Set<String>) -> Bool {
        switch floor.tools {
        case .unbounded:
            return true
        case .fixed(let set):
            return set.contains(toolName)
        case .fromBinding:
            return boundTools.contains(toolName)
        }
    }
}
