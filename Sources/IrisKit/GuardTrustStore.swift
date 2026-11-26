import CryptoKit
import Foundation

/// #1295 (b'): which library/ and artifacts/ contents Iris itself wrote from a clean conversation, so a later
/// `read_file` of exactly those bytes may skip the guard as a first-party read does. Everything else there (a
/// `run_command` write, a tainted turn's write, an outside edit) is judged.
///
/// Trust is per content, not per path: the list is `sha256(content)`s. It lives in `config/`, a protected
/// directory (Brian, #1369: "no HMAC, protected file"): `write_file` there is a protected write and a host
/// command naming it is a person's call, even under YOLO (#1315, #1326). Best effort for a command that builds
/// the path at run time, like every command-text check: a variable-built path, a glob, a decoded path or a link
/// made earlier runs unasked under YOLO, a residual Brian accepted (#1373, with the HMAC option). A missing or unreadable list trusts nothing, so the
/// reads it covered are judged: it fails closed.
final class GuardTrustStore: @unchecked Sendable {
    static let shared = GuardTrustStore(file: IrisPaths.default.configDir.appendingPathComponent("guard-trust.json"))

    private let file: URL
    private let lock = NSLock()

    init(file: URL) {
        self.file = file
    }

    /// Whether `path` (resolved) is under library/ or artifacts/: the folders written unheld (#814), the only
    /// ones this list vouches for. Iris's other first-party files are trusted by `IrisEngine.isFirstPartyRead`.
    static func covers(_ path: String, paths: IrisPaths = .default) -> Bool {
        let target = IrisPaths.realPath(path).lowercased()
        return [paths.libraryDir, paths.artifactsDir].contains { dir in
            target.hasPrefix(IrisPaths.realPath(dir.path).lowercased() + "/")
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Records `content` as written to `path` by a clean conversation. One entry per path: a later write to the
    /// same path replaces it, so the list stays the size of the folders.
    func recordCleanWrite(path: String, content: String) {
        let hash = Self.sha256(Data(content.utf8))
        let resolved = IrisPaths.realPath(path)
        lock.withLock {
            var entries = load()
            entries = entries.filter { $0.value != resolved }
            entries[hash] = resolved
            save(entries)
        }
    }

    /// Whether `data` is content a clean conversation wrote.
    func isClean(_ data: Data) -> Bool {
        let hash = Self.sha256(data)
        return lock.withLock { load()[hash] != nil }
    }

    /// #1374: drops each entry whose file is gone or no longer hashes to its key, so a deleted or edited note's
    /// entry doesn't stay forever. At launch only (`IrisApp.openStore`, off main), never on a read, which already loads
    /// and rewrites the whole list (#1402). It only ever removes trust: a missing or undecodable list is left as
    /// it is, still trusting nothing. Returns how many entries it dropped.
    @discardableResult
    func pruneStale() -> Int {
        lock.withLock {
            guard let data = try? Data(contentsOf: file),
                  let entries = try? JSONDecoder().decode([String: String].self, from: data) else { return 0 }
            let kept = entries.filter { hash, path in
                FileManager.default.contents(atPath: path).map { Self.sha256($0) == hash } ?? false
            }
            guard kept.count < entries.count else { return 0 }
            save(kept)
            return entries.count - kept.count
        }
    }

    /// `[sha256: path]`. Anything that doesn't decode is an empty list.
    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save(_ entries: [String: String]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
