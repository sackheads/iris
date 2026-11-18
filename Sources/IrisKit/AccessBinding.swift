import Foundation

/// A run acts *as* an `AccessProfile`, capped by its `Principal` floor (spec §3). Rights live on
/// the profile; the floor sets how low the ceiling is. `isOwner` is the Invariant-1 axis: a
/// subagent whose spawner's binding is owner inherits `isOwner == true` and keeps the unbounded
/// `.owner` profile even though its `Principal` is `.subagent` — the floor only ever constrains the
/// *sandbox* placement and the axes `PrincipalFloor` actually caps, never demotes an owner
/// binding's other axes.
///
/// Named `AccessBinding`, not the spec's bare "Binding": `SwiftUI.Binding<Value>` is already used
/// throughout this module, and a same-named non-generic type shadows it at every call site.
public struct AccessBinding: Equatable, Sendable {
    public let profile: AccessProfile
    public let principal: Principal
    public let isOwner: Bool

    public init(profile: AccessProfile, principal: Principal, isOwner: Bool) {
        self.profile = profile
        self.principal = principal
        self.isOwner = isOwner
    }

    /// Caps `profile` by `floor`, per axis (planner's ruling on #1201 review finding 4: the floor
    /// is the H2 capability backstop, not the assigned profile alone — relying only on a minimal
    /// profile at the call site is exactly the "policy, not a capability floor" shape H2 rejects).
    /// `tools`/`credentials`/`transports` clamp by set intersection; `memoryRead`/`memoryWrite`
    /// clamp to at most the floor's fixed tier. `fsRoots`/`skills` are not floor axes (Task 1) and
    /// pass through unchanged.
    public func capped(by floor: PrincipalFloor) -> AccessBinding {
        AccessBinding(
            profile: AccessProfile(
                credentials: Self.cappedSet(profile.credentials, by: floor.credentials),
                memoryRead: Self.cappedTier(profile.memoryRead, by: floor.memoryRead),
                memoryWrite: Self.cappedTier(profile.memoryWrite, by: floor.memoryWrite),
                transports: Self.cappedSet(profile.transports, by: floor.transports),
                fsRoots: profile.fsRoots,
                skills: profile.skills,
                tools: Self.cappedTools(profile.tools, by: floor.tools)
            ),
            principal: principal,
            isOwner: isOwner
        )
    }

    /// `.unbounded`/`.fromBinding` both mean "pass the grant through unchanged" here — the
    /// distinction between them only matters to `PrincipalFloor.isAllowed`'s dispatch-time read.
    private static func cappedSet<Element>(_ grant: Set<Element>, by cap: AxisCap<Set<Element>>) -> Set<Element> {
        switch cap {
        case .unbounded, .fromBinding:
            return grant
        case .fixed(let allowed):
            return grant.intersection(allowed)
        }
    }

    private static func cappedTier(_ tier: MemoryTier, by cap: AxisCap<MemoryTier>) -> MemoryTier {
        switch cap {
        case .unbounded, .fromBinding:
            return tier
        case .fixed(let ceiling):
            return min(tier, ceiling)
        }
    }

    private static func cappedTools(_ grant: ToolGrant, by cap: AxisCap<Set<String>>) -> ToolGrant {
        switch cap {
        case .unbounded, .fromBinding:
            return grant
        case .fixed(let floorSet):
            switch grant {
            case .allTools:
                return .set(floorSet)
            case .set(let grantSet):
                return .set(grantSet.intersection(floorSet))
            }
        }
    }
}
