import Foundation

/// #1397: how tier 3 judges a read from a registered external library. Brian, on a work vault Gemini already
/// scans: "at most it should be an *option* to use cloud or gemini (or maybe none at all)."
enum LibraryGuardMode: String, Codable, CaseIterable, Sendable {
    /// The guard check runs on this Mac, whatever the global engine: the global one when it is local, else
    /// llama.cpp's gemma. The note still goes to the chat model when Iris reads it.
    case local
    /// The configured cloud canary, whatever the global engine: the note also goes to the canary's provider,
    /// which can differ from the chat provider.
    case cloud
    /// No tier 3. Tier 1's strip, the `<untrusted_context>` wrap and the conversation's taint all stay.
    case none
}

/// The library roots and their modes, set only from Settings, never from the model-maintained
/// `library/EXTERNAL_LIBRARIES.md` (a tainted turn could otherwise set its own library to `none`). It lives in
/// `config/`, a protected directory like `guard-trust.json` (#1369): `write_file` there is a protected write and
/// a host command naming it is a person's call, even under YOLO (#1315, #1326), best effort for a path built at
/// run time (#1373). A missing file names no roots, so each read is judged by the global settings, as before
/// #1397. One that is there but doesn't decode (a mode this build doesn't know too) sends every guarded tool
/// result to `local`: which paths were a vault's can't be told, so none goes to a cloud canary.
final class LibraryGuardStore: @unchecked Sendable {
    static let shared = LibraryGuardStore(file: IrisPaths.default.configDir.appendingPathComponent("library-guard.json"))

    struct Entry: Codable, Equatable, Sendable {
        /// Resolved through `IrisPaths.realPath` when set, so a link to the folder isn't a second root.
        var root: String
        var mode: LibraryGuardMode
    }

    let file: URL
    private let lock = NSLock()

    init(file: URL) {
        self.file = file
    }

    func entries() -> [Entry] {
        lock.withLock { load() }
    }

    /// The mode for a read of `path`, or nil when it is under no root: the deepest root it is under, after
    /// resolving both, so a symlink or `..` can't put a path under a root it isn't really in.
    func mode(for path: String) -> LibraryGuardMode? {
        Self.mode(for: path, in: entries())
    }

    static func mode(for path: String, in entries: [Entry]) -> LibraryGuardMode? {
        let target = IrisPaths.realPath(path).lowercased()
        return entries
            .map { (root: IrisPaths.realPath($0.root).lowercased(), mode: $0.mode) }
            .filter { target == $0.root || target.hasPrefix($0.root + "/") }
            .max { $0.root.count < $1.root.count }?.mode
    }

    /// Adds `root`, or changes its mode.
    func set(root: String, mode: LibraryGuardMode) {
        let resolved = IrisPaths.realPath(root)
        lock.withLock {
            var entries = load().filter { $0.root != resolved }
            entries.append(Entry(root: resolved, mode: mode))
            save(entries.sorted { $0.root < $1.root })
        }
    }

    func remove(root: String) {
        let resolved = IrisPaths.realPath(root)
        lock.withLock { save(load().filter { $0.root != resolved }) }
    }

    /// The mode a guarded tool result is judged under (#1397): `local` for every one while the file is there but
    /// doesn't decode (which paths were a vault's can't be told, so none goes to a cloud canary), else the mode of the
    /// root `path` is under, else nil (the global settings). `path` is a `read_file`'s, nil for other
    /// tools: a `run_command` that prints a note follows the global settings (planner, #1403).
    func readMode(_ path: String?) -> LibraryGuardMode? {
        let state: [Entry]? = lock.withLock {
            guard let data = try? Data(contentsOf: file) else { return [] }
            return try? JSONDecoder().decode([Entry].self, from: data)
        }
        guard let entries = state else { return .local }
        return path.flatMap { Self.mode(for: $0, in: entries) }
    }

    /// The file is there but doesn't decode: every guarded tool result is judged `local` until it's fixed, and
    /// Settings says so.
    var isUnreadable: Bool {
        lock.withLock {
            guard let data = try? Data(contentsOf: file) else { return false }
            return (try? JSONDecoder().decode([Entry].self, from: data)) == nil
        }
    }

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
