import Foundation

/// What a `mutating` job was granted at creation (#282, spec §1): the host directories its
/// container mounts and its host file tools may use, and whether its commands may reach the
/// network. Stored inside `JobPolicy.grants`, so an older build reads a granted job as an
/// ungranted one — the safe direction — and there is no jobs migration.
struct JobGrant: Codable, Equatable, Sendable {
    /// Ordered. The first read-write entry is the working directory (§0.6). Sources are stored
    /// canonical (`IrisPaths.canonicalPath`) by the tools that create a grant.
    var mounts: [ContainerMount]
    /// `false` attaches the container to the host-only `iris-isolated` network with no DNS (§0.7).
    var network: Bool

    init(mounts: [ContainerMount] = [], network: Bool = false) {
        self.mounts = mounts
        self.network = network
    }

    /// The run's working directory and the hidden conversation's `workspacePath`; nil means `/`.
    var workingDirectory: String? { mounts.first(where: { !$0.readOnly })?.source }

    /// The mounts in the runtime's `source[:target][:ro]` grammar.
    var mountEntries: [String] { mounts.map(\.entry) }

    private enum CodingKeys: String, CodingKey { case mounts, network }

    /// Invariant 1 on both keys. A mount that will not parse throws on purpose: half a grant is
    /// not a grant, and `JobPolicy`'s decoder turns the throw into "no grant".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mounts = try c.decodeIfPresent([ContainerMount].self, forKey: .mounts) ?? []
        network = try c.decodeIfPresent(Bool.self, forKey: .network) ?? false
    }
}
