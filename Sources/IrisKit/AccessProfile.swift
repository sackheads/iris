import Foundation

/// An opaque reference to a typed account in the #966 credential registry. Here it is a leaf type;
/// the registry resolves it to an actual spendable credential.
public struct AccountRef: Codable, Hashable, Sendable {
    public let type: String
    public let id: String
    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }
}

/// A coarse, ordered memory-tier lattice (spec F4). `.none` is the deny-all floor.
public enum MemoryTier: Int, Comparable, Codable, Sendable {
    case none = 0
    case task
    case shared
    case conversations
    case full

    public static func < (lhs: MemoryTier, rhs: MemoryTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Builder-left mechanism (coarse sets for now; namespaces later if a real case needs them).
public typealias TransportGrant = Set<String>
public typealias FSGrant = Set<String>
public typealias SkillGrant = Set<String>

/// The positive tool allowlist an `AccessProfile` grants. `.set` is a concrete, possibly-empty
/// allowlist (empty = deny-all); `.allTools` is the sentinel only `AccessProfile.owner` carries —
/// the dispatcher reads it as unbounded only under `.main`, and it is never produced by decoding.
public enum ToolGrant: Codable, Equatable, Sendable {
    case set(Set<String>)
    case allTools

    public var isEmpty: Bool {
        if case .set(let names) = self { return names.isEmpty }
        return false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = .set(try container.decode(Set<String>.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .set(let names):
            try container.encode(names)
        case .allTools:
            // Never round-trips back to .allTools on decode — it is a leaf-constant sentinel, not
            // a persisted shape. Encoding is only exercised if something serializes .owner, which
            // the H3 not-model-writable store never does.
            try container.encode(["*"])
        }
    }
}

/// The user-configured grant (spec "the only thing the user configures" — the #961 pane). Every
/// axis has an explicit deny-all zero value; a decoded profile with an axis key omitted decodes to
/// that zero value, never to all-access (C8) — because every decoded profile is non-owner.
/// `.owner` is the one and only owner profile, a `static let` constant that is never decoded.
public struct AccessProfile: Codable, Equatable, Sendable {
    public var credentials: Set<AccountRef>
    public var memoryRead: MemoryTier
    public var memoryWrite: MemoryTier
    public var transports: TransportGrant
    public var fsRoots: FSGrant
    public var skills: SkillGrant
    public var tools: ToolGrant
    /// #974 Task 16: the session roles a guest bound to this profile may address (`role:<name>`), the
    /// message-addressing reach `ProviderTokenRegistry` roles carry today. Normalised names
    /// (`SessionRoles.normalizedName`). Not a `PrincipalFloor` axis: the guest floor fixes `transports` to
    /// `[]`, so folding roles into it would zero every grant. Deny-all by default.
    public var peerRoles: Set<String>

    public init(credentials: Set<AccountRef> = [], memoryRead: MemoryTier = .none, memoryWrite: MemoryTier = .none,
               transports: TransportGrant = [], fsRoots: FSGrant = [], skills: SkillGrant = [],
               tools: ToolGrant = .set([]), peerRoles: Set<String> = []) {
        self.credentials = credentials
        self.memoryRead = memoryRead
        self.memoryWrite = memoryWrite
        self.transports = transports
        self.fsRoots = fsRoots
        self.skills = skills
        self.tools = tools
        self.peerRoles = peerRoles
    }

    private enum CodingKeys: String, CodingKey {
        case credentials, memoryRead, memoryWrite, transports, fsRoots, skills, tools, peerRoles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credentials = try container.decodeIfPresent(Set<AccountRef>.self, forKey: .credentials) ?? []
        memoryRead = try container.decodeIfPresent(MemoryTier.self, forKey: .memoryRead) ?? .none
        memoryWrite = try container.decodeIfPresent(MemoryTier.self, forKey: .memoryWrite) ?? .none
        transports = try container.decodeIfPresent(TransportGrant.self, forKey: .transports) ?? []
        fsRoots = try container.decodeIfPresent(FSGrant.self, forKey: .fsRoots) ?? []
        skills = try container.decodeIfPresent(SkillGrant.self, forKey: .skills) ?? []
        tools = try container.decodeIfPresent(ToolGrant.self, forKey: .tools) ?? .set([])
        // A name that does not normalise is dropped: a narrower grant, never a wider one.
        peerRoles = Set((try container.decodeIfPresent([String].self, forKey: .peerRoles) ?? []).compactMap(SessionRoles.normalizedName))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(credentials, forKey: .credentials)
        try container.encode(memoryRead, forKey: .memoryRead)
        try container.encode(memoryWrite, forKey: .memoryWrite)
        try container.encode(transports, forKey: .transports)
        try container.encode(fsRoots, forKey: .fsRoots)
        try container.encode(skills, forKey: .skills)
        try container.encode(tools, forKey: .tools)
        try container.encode(peerRoles.sorted(), forKey: .peerRoles)
    }

    /// Full access on every axis — what `main` runs as. Never decoded; `Binding.isOwner` is what
    /// actually bypasses per-axis checks for this profile, so its set-valued axes are left empty
    /// rather than given a parallel "unbounded" sentinel each.
    public static let owner = AccessProfile(memoryRead: .full, memoryWrite: .full, tools: .allTools)
}
