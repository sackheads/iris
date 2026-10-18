import CryptoKit
import Foundation

/// Which workspace `.iris/` files Iris trusts (#625, Brian's (b)): only those it wrote itself, or
/// that a person trusted from "Review Workspace Rules…". A file Iris did not write, whether planted by
/// the VM in a nested `.iris/` the read-only mount does not cover, shipped by a cloned repository
/// or edited by hand, reads as absent until the person trusts it.
///
/// The record is one fingerprint per file, kept in `config/workspace-trust.json` under Iris's own
/// home: a protected write directory (`IrisPaths.protectedWriteDirs`), so no auto-allow writes it,
/// no unattended run does, and the sandbox never mounts it. Keyed by the workspace's real path,
/// lowercased, the same normalisation `HomeMount` uses, so the two agree on which folder is which.
struct WorkspaceIrisTrust: Sendable {
    /// The files whose rules decide what runs unasked.
    static let files = ["vibecop.md", "permissions.json", "sandbox.json"]

    let paths: IrisPaths

    init(paths: IrisPaths = .default) { self.paths = paths }

    private var storeURL: URL { paths.configDir.appendingPathComponent("workspace-trust.json") }

    static func key(_ workspace: String) -> String {
        IrisPaths.canonicalPath(IrisEngine.expandTilde(workspace)).lowercased()
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `data`, read from `<workspace>/.iris/<file>`, is what Iris last recorded there.
    func isTrusted(_ file: String, workspace: String, data: Data) -> Bool {
        load()[Self.key(workspace)]?[file] == Self.fingerprint(data)
    }

    /// Records `data` as trusted for `<workspace>/.iris/<file>`; nil forgets it (a removed file).
    func record(_ file: String, workspace: String, data: Data?) {
        Self.lock.withLock {
            var store = load()
            let key = Self.key(workspace)
            var entry = store[key] ?? [:]
            entry[file] = data.map(Self.fingerprint)
            store[key] = entry.isEmpty ? nil : entry
            save(store)
        }
    }

    /// The workspace's rule files Iris would not use as they stand, with their content as the
    /// link-checked reader sees it, for the person to review.
    func untrusted(workspace: String) -> [(file: String, data: Data)] {
        Self.files.compactMap { file in
            guard let data = WorkspaceIrisDir.readUnverified(file, workspace: workspace),
                  !isTrusted(file, workspace: workspace, data: data) else { return nil }
            return (file, data)
        }
    }

    /// The person's "Trust These Rules": exactly the files and content the sheet showed, and only
    /// while each still reads that way (#625 review). Recording what is on disk at the click would
    /// trust whatever a VM swapped in after the person looked, or a file the sheet never showed.
    /// False, with nothing recorded, when any of them changed. Called only from the UI.
    @discardableResult
    func trustReviewed(_ reviewed: [(file: String, data: Data)], workspace: String) -> Bool {
        guard reviewed.allSatisfy({ WorkspaceIrisDir.readUnverified($0.file, workspace: workspace) == $0.data }) else {
            return false
        }
        for entry in reviewed { record(entry.file, workspace: workspace, data: entry.data) }
        return true
    }

    /// Records `written` for a file Iris just wrote, only if the file still holds exactly that.
    @discardableResult
    func recordWritten(_ file: String, workspace: String, written: Data) -> Bool {
        guard WorkspaceIrisDir.readUnverified(file, workspace: workspace) == written else { return false }
        record(file, workspace: workspace, data: written)
        return true
    }

    // Process-wide: two writers updating different entries must not lose one.
    private static let lock = NSLock()

    private func load() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: storeURL) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    private func save(_ store: [String: [String: String]]) {
        try? FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
