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

    /// #974 Task 15, dev-3 review finding 1: the most restrictive of two guest-steered bindings,
    /// for a stamp that must combine rather than pick a side (a merged steer batch from several
    /// guests, or a fresh queued guest arriving while a narrower one's turn is still running).
    /// First-wins or last-wins both let a wider guest's binding leak onto a narrower guest's turn
    /// once per-guest profiles exist (#965/Task 16's retrofit) — today every guest shares one
    /// floor, so this is latent rather than exploitable, but the stamp exists for the day it
    /// isn't. Comparable via `BindingResolver.isSubGrant` (every axis narrower-or-equal); when
    /// neither is a subgrant of the other, fails closed to the `.mcpGuest` floor rather than
    /// guessing which axis matters more.
    public static func meetGuestBindings(_ a: AccessBinding, _ b: AccessBinding) -> AccessBinding {
        if BindingResolver.isSubGrant(a.profile, of: b.profile) { return a }
        if BindingResolver.isSubGrant(b.profile, of: a.profile) { return b }
        return AccessBinding(profile: AccessProfile(), principal: .mcpGuest, isOwner: false)
            .capped(by: PrincipalFloor.floor(for: .mcpGuest))
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
