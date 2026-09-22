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
    /// - Parameter fileExists: the existence check, injectable so a test can decide the answer
    ///   without a directory on disk.
    static func canonical(_ raw: String,
                          fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        guard fileExists(standardized.path) else { return nil }
        return standardized.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
