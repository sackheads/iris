import Foundation

/// The positive-allowlist shape of a single axis's Principal cap (#974 Task 1, generalized per the
/// planner's ruling on #1201 review finding 4). `.fixed` names the exact value up front (a guest
/// or the disclosure broker); `.fromBinding` defers to the run's own `AccessProfile` grant on that
/// axis, because a subagent/evaluator does arbitrary *bounded* work, not a fixed shape of it;
/// `.unbounded` is `.main`'s only shape. `.fromBinding` and `.unbounded` behave identically under
/// `AccessBinding.capped(by:)` (both mean "pass the profile's own value through unchanged") — they
/// are kept distinct only because `PrincipalFloor.isAllowed` reads `.fromBinding` differently from
/// a dispatcher that already has the bound value in hand.
public enum AxisCap<Value: Equatable & Sendable>: Equatable, Sendable {
    case unbounded
    case fixed(Value)
    case fromBinding
}

/// The non-negotiable per-Principal cap (spec "the fixed code floor"): a cap, never a grant. H2
/// requires this for the disclosure broker specifically — "it cannot run a command, write a file,
/// **spend a credential, or reach a transport**" is a floor-level guarantee, not a property the
/// *assigned profile* happens to have; relying on a minimal profile alone is exactly the
/// policy-not-capability-floor shape H2 rejected (planner's ruling on #1201 review finding 4). So
/// the floor caps every axis a Principal's non-negotiable rules constrain — tools, credentials,
/// memory read/write, transports — not only tools. `fsRoots`/`skills` are not floor axes here (no
/// Principal in this plan has a fixed, non-profile-derived FS/skill cap); every non-`.main` floor
/// is sandbox-only and never foreground.
public struct PrincipalFloor: Equatable, Sendable {
    public let tools: AxisCap<Set<String>>
    public let credentials: AxisCap<Set<AccountRef>>
    public let memoryRead: AxisCap<MemoryTier>
    public let memoryWrite: AxisCap<MemoryTier>
    public let transports: AxisCap<Set<String>>
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
            return PrincipalFloor(tools: .unbounded, credentials: .unbounded, memoryRead: .unbounded,
                                  memoryWrite: .unbounded, transports: .unbounded,
                                  sandboxOnly: false, foreground: true)
        case .mcpGuest:
            // A guest spends no credential, writes no memory and reaches no transport by floor
            // (deny-all on each); its memory read is the least tier — task context only, per the
            // spec's "guest profiles -> least" (no personal memory/facts/private skills).
            return PrincipalFloor(tools: .fixed(GuestToolset.allowedNames), credentials: .fixed([]),
                                  memoryRead: .fixed(.task), memoryWrite: .fixed(.none), transports: .fixed([]),
                                  sandboxOnly: true, foreground: false)
        case .broker:
            // H2's full capability floor: owner memory READ only (fixed at .full — it exists to
            // answer from owner memory), ZERO acting tools, zero credentials, zero transports,
            // and it writes nothing.
            return PrincipalFloor(tools: .fixed(brokerTools), credentials: .fixed([]),
                                  memoryRead: .fixed(.full), memoryWrite: .fixed(.none), transports: .fixed([]),
                                  sandboxOnly: true, foreground: false)
        case .subagent, .evaluator:
            // Arbitrary bounded work: every axis's positive allowlist is the inherited Binding's
            // own grant (Task 2's `AccessProfile`), not a fixed Principal value. `SubagentManager`
            // governs the actual cap via `parent ∩ floor` (parent binding capped by the child's
            // Principal floor) — this floor adds no cap of its own on top of that.
            return PrincipalFloor(tools: .fromBinding, credentials: .fromBinding, memoryRead: .fromBinding,
                                  memoryWrite: .fromBinding, transports: .fromBinding,
                                  sandboxOnly: true, foreground: false)
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
