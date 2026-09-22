import Foundation

/// The one spelling of a watched directory (#187 deliverable 4, spec §1).
///
/// A watch root is stored canonical and matched lexically: FSEvents reports paths under the root
/// it was given, and a delete event names a path that no longer exists, so the events cannot be
/// stat'ed one by one to find out where they really are. That only works if the root itself has
/// been resolved once, up front — `/tmp/notes` and `/private/tmp/notes` are the same directory, and
/// a watch stored under the first spelling silently matches nothing when FSEvents reports the
/// second.
enum WatchRoot {
    /// `raw` with `~` expanded, `..` resolved, symlinks resolved and the result standardised —
    /// or `nil` when nothing exists at that path.
    ///
    /// `nil` rather than a best effort, because every caller has to make its own decision about a
    /// root that is not there: the tool refuses it, the migration leaves the row as it found it,
    /// and the launch check pauses the job. Guessing a canonical form for a path nobody can stat
    /// would hide all three.
    ///
    /// `..` is resolved *through the file system*, not lexically: `standardizedFileURL` — measured,
    /// 2026-09-22 — follows a symlink before removing the `..` above it, so `/tmp/link/../notes`
    /// lands beside what `link` points at, not beside `link`. (`URL.standardized` is the lexical
    /// one; this is not it.) `IrisPaths.canonicalPath` resolves the same way and the two must
    /// agree, so this is consistency rather than a choice — but a caller that refuses roots should
    /// know that a `..` in an argument can walk out of the directory it appears to be in.
    ///
    /// - Parameter fileExists: the existence check, injectable so a test can decide the answer
    ///   without a directory on disk.
    static func canonical(_ raw: String,
                          fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    -> String? {
        // `IrisEngine.expandTilde`, not `expandingTildeInPath`: Foundation's truncates to PATH_MAX
        // and returns a plausible path (#275), and a watch on a truncated root would be a watch on
        // a directory other than the one named. What refuses an over-long root is that no such
        // directory can exist, and that has to be asked of the full path.
        let expanded = IrisEngine.expandTilde(raw)
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        guard fileExists(standardized.path) else { return nil }
        return standardized.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The directories a watch on which would be a watch on the machine (spec §5). Compared by
    /// canonical form, so `/var` here also turns down `/private/var`; a volume root
    /// (`/Volumes/<name>`) and the home directory are refused too, by `refusal(for:paths:home:)`.
    /// Only the root itself is too broad — a folder *under* `/private` or `/Users` is exactly what a
    /// watch is for.
    static let tooBroad = ["/", "/System", "/Library", "/usr", "/private", "/var", "/etc", "/bin", "/sbin"]

    static let tooBroadRefusal = "that is too broad to watch; name a specific folder"

    /// Iris's whole directory, not only `config` and `plugins`: `update_memory`, `save_fact` and
    /// `update_soul` write under `~/.iris/memory` through their own managers, where the self-write
    /// filter (spec §4) cannot see them, so a watch anywhere over that tree would fire on the run's
    /// own notes and the run would write more of them.
    static let protectedRefusal = "that path is or contains Iris's own directory (~/.iris); a watch there would react to itself"

    /// Why `canonical` may not be watched, or nil when it may. Checked in the order a reader would
    /// want the answer: a root that is too broad is told so even when it also contains Iris's
    /// directory (the home directory does), because "name a specific folder" is the fix for both.
    ///
    /// Both sides go through `IrisPaths.canonicalPath` and are compared case-insensitively — the
    /// same rule as `IrisPaths.isUnderProtectedWriteDir`, and for the same reason: the default
    /// volume is case-insensitive and `/var` is a symlink. Unlike that check, this one refuses in
    /// both directions — a root that *contains* Iris's directory sees every write into it — which is
    /// why it is not written as a call to it.
    ///
    /// - Parameters:
    ///   - paths: where Iris's own directory is; injected so a test can refuse a temp root.
    ///   - home: the user's home directory, injected for the same reason.
    static func refusal(for canonical: String, paths: IrisPaths, home: String) -> String? {
        let root = IrisPaths.canonicalPath(canonical).lowercased()
        let broad = (tooBroad + [home]).map { IrisPaths.canonicalPath($0).lowercased() }
        if broad.contains(root) { return tooBroadRefusal }
        let components = URL(fileURLWithPath: root).pathComponents
        if components.count == 3, components[1] == "volumes" { return tooBroadRefusal }
        let iris = IrisPaths.canonicalPath(paths.root.path).lowercased()
        if root == iris || root.hasPrefix(iris + "/") || iris.hasPrefix(root + "/") {
            return protectedRefusal
        }
        return nil
    }
}
