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
}
