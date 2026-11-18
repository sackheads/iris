import Foundation

/// The outcome of resolving a run's binding: either a bound `AccessBinding`, or a refusal with a
/// reason. There is no third option — a run with no binding never falls back to owner (H3).
public enum BindingResolution: Equatable, Sendable {
    case bound(AccessBinding)
    case refused(reason: String)
}

public enum BindingResolver {
    /// No identity or requested drop may ever resolve to this id directly (H3) — `owner` is
    /// reachable only through the `.main`-with-no-drop default path.
    private static let reservedOwnerId = "owner"

    /// The at-the-door route path: resolves an authenticated identity (never a self-asserted name
    /// from a task body) to a profile, per spec M4/H3. Internal (not `public`): `IdentityKey` and
    /// `AccessProfileStore` are themselves internal.
    static func resolveBinding(principal: Principal, identity: IdentityKey?,
                               requestedDrop: String?, store: AccessProfileStore) -> BindingResolution {
        if principal == .main {
            guard let requestedDrop else {
                return .bound(AccessBinding(profile: .owner, principal: .main, isOwner: true))
            }
            return dropInto(requestedDrop, from: .owner, store: store) { profile in
                AccessBinding(profile: profile, principal: .main, isOwner: false)
            }
        }

        guard let identity else {
            return .refused(reason: "no authenticated identity for \(principal)")
        }
        guard let sourceId = store.allMappings()[identity], sourceId != reservedOwnerId,
              let source = store.profile(id: sourceId) else {
            return .refused(reason: "identity is not mapped to a live, non-owner profile")
        }
        guard let requestedDrop else {
            return .bound(AccessBinding(profile: source, principal: principal, isOwner: false))
        }
        return dropInto(requestedDrop, from: source, store: store) { profile in
            AccessBinding(profile: profile, principal: principal, isOwner: false)
        }
    }

    /// The on-load path: re-resolves a `Conversation`'s persisted `accessProfileId` (Task 5). A
    /// non-nil id naming no live profile refuses for every principal, `.main` included (Anti-goal:
    /// a missing/unreadable profile must never resolve to owner); only a nil id defaults to owner,
    /// and only for `.main`. Internal (not `public`): `AccessProfileStore` is itself internal.
    static func resolveBinding(principal: Principal, persistedProfileId: String?,
                               store: AccessProfileStore) -> BindingResolution {
        guard let persistedProfileId else {
            guard principal == .main else {
                return .refused(reason: "no persisted profile for \(principal)")
            }
            return .bound(AccessBinding(profile: .owner, principal: .main, isOwner: true))
        }
        if persistedProfileId == reservedOwnerId {
            guard principal == .main else {
                return .refused(reason: "owner is reachable only by main")
            }
            return .bound(AccessBinding(profile: .owner, principal: .main, isOwner: true))
        }
        guard let profile = store.profile(id: persistedProfileId) else {
            return .refused(reason: "persisted profile '\(persistedProfileId)' no longer exists")
        }
        return .bound(AccessBinding(profile: profile, principal: principal, isOwner: false))
    }

    /// Shared drop-into-a-named-profile logic for both entry points: the reserved id is barred,
    /// the target must exist, and it must be a sub-grant of `source` on every axis — never widen.
    private static func dropInto(_ requestedDrop: String, from source: AccessProfile, store: AccessProfileStore,
                                 bind: (AccessProfile) -> AccessBinding) -> BindingResolution {
        guard requestedDrop != reservedOwnerId,
              let target = store.profile(id: requestedDrop),
              isSubGrant(target, of: source) else {
            return .refused(reason: "'\(requestedDrop)' is not a known profile that narrows the source on every axis")
        }
        return .bound(bind(target))
    }

    /// True when `target` is narrower than or equal to `source` on **every** axis (spec C3) — a
    /// majority of narrower axes never outweighs one that is wider.
    public static func isSubGrant(_ target: AccessProfile, of source: AccessProfile) -> Bool {
        guard target.credentials.isSubset(of: source.credentials) else { return false }
        guard target.memoryRead <= source.memoryRead else { return false }
        guard target.memoryWrite <= source.memoryWrite else { return false }
        guard target.transports.isSubset(of: source.transports) else { return false }
        guard isFSSubset(target.fsRoots, of: source.fsRoots) else { return false }
        guard target.skills.isSubset(of: source.skills) else { return false }
        guard isToolSubset(target.tools, of: source.tools) else { return false }
        return true
    }

    /// FS roots compared after resolving symlinks (carried F4 decision): a root reached only via a
    /// symlink to a path the source already grants must not count as wider. Mount-overlap (one
    /// root a parent directory of another, or bind-mount aliasing) is intentionally left open —
    /// // OPEN: not handled here; flagged for Brian/the builder per the plan.
    private static func isFSSubset(_ target: FSGrant, of source: FSGrant) -> Bool {
        let resolvedTarget = Set(target.map(resolvedPath))
        let resolvedSource = Set(source.map(resolvedPath))
        return resolvedTarget.isSubset(of: resolvedSource)
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// `.allTools` is the owner sentinel: anything is a sub-grant of it, but it is never itself a
    /// sub-grant of a concrete set (it would widen).
    private static func isToolSubset(_ target: ToolGrant, of source: ToolGrant) -> Bool {
        switch (target, source) {
        case (_, .allTools):
            return true
        case (.allTools, .set):
            return false
        case (.set(let targetSet), .set(let sourceSet)):
            return targetSet.isSubset(of: sourceSet)
        }
    }
}
