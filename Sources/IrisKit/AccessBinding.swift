import Foundation

/// A run acts *as* an `AccessProfile`, capped by its `Principal` floor (spec §3). Rights live on
/// the profile; the floor sets how low the ceiling is. `isOwner` is the Invariant-1 axis: a
/// subagent whose spawner's binding is owner inherits `isOwner == true` and keeps the unbounded
/// `.owner` profile even though its `Principal` is `.subagent` — the floor only ever constrains the
/// *sandbox* placement and the tools axis, never demotes an owner binding's other axes.
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

    /// Caps `profile` by `floor`, per axis. `PrincipalFloor` (Task 1) carries only a tools cap —
    /// `sandboxOnly`/`foreground` are consulted directly by the caller, not folded into the
    /// profile — so this narrows only the `tools` axis; every other axis (credentials, memory,
    /// transports, FS, skills) passes through unchanged. A dedicated minimal profile for a
    /// zero-acting-tools Principal like `.broker` is the resolver's job (Task 4/5): capping an
    /// already-wide profile by a fixed-tools floor narrows what it may *call*, not what it is
    /// nominally *granted* on axes the floor does not speak to.
    public func capped(by floor: PrincipalFloor) -> AccessBinding {
        AccessBinding(
            profile: AccessProfile(
                credentials: profile.credentials,
                memoryRead: profile.memoryRead,
                memoryWrite: profile.memoryWrite,
                transports: profile.transports,
                fsRoots: profile.fsRoots,
                skills: profile.skills,
                tools: Self.cappedTools(profile.tools, by: floor.tools)
            ),
            principal: principal,
            isOwner: isOwner
        )
    }

    private static func cappedTools(_ grant: ToolGrant, by cap: ToolCap) -> ToolGrant {
        switch cap {
        case .unbounded:
            return grant
        case .fromBinding:
            // The floor defers to the binding's own grant — no further narrowing.
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
