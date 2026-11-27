import Foundation

/// #1435: the `vcs` tool's push and PR policy, set only from Settings. It lives in `config/`, a protected
/// directory like `library-guard.json`: `write_file` there is a protected write and a host command naming it is
/// a person's call (best effort for a path built at run time). A missing file is the defaults. One that is
/// there but doesn't decode refuses every `vcs` action that writes, since which paths were meant to be
/// protected can't be told.
final class VCSPolicyStore: @unchecked Sendable {
    static let shared = VCSPolicyStore(file: IrisPaths.default.configDir.appendingPathComponent("vcs-policy.json"))

    struct Policy: Codable, Equatable, Sendable {
        /// A changed file at one of these paths, or under one ending in `/`, refuses the PR (compared ignoring case).
        var protectedPaths: [String]

        static let defaults = Policy(protectedPaths: [
            ".github/workflows/", ".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS",
            "docs/plans/", "docs/specs/", ".gitmodules",
        ])

        func protects(_ path: String) -> Bool {
            let p = path.lowercased()
            return protectedPaths.contains { entry in
                let e = entry.lowercased()
                return e.hasSuffix("/") ? p.hasPrefix(e) : p == e
            }
        }
    }

    enum Loaded: Equatable { case policy(Policy), unreadable }

    let file: URL
    private let lock = NSLock()

    init(file: URL) {
        self.file = file
    }

    func load() -> Loaded {
        lock.withLock {
            guard FileManager.default.fileExists(atPath: file.path) else { return .policy(.defaults) }
            guard let data = try? Data(contentsOf: file), let policy = try? JSONDecoder().decode(Policy.self, from: data) else {
                return .unreadable
            }
            return .policy(policy)
        }
    }
}
