import Foundation

/// What an unattended run has just written, so a watch does not react to Iris's own output
/// (#187 deliverable 4, spec §4, ruling R-D4-1).
///
/// The loop this exists to break is the one the design doc names: a watch whose run summarises a
/// folder into a file *in that folder*, which the watch sees, which fires the run again. The
/// filter is a memory rather than a lock because the write and the event are in different places
/// and seconds apart — the tool dispatcher records the path it wrote, FSEvents reports it a
/// moment later, and the coordinator asks whether it was ours.
///
/// **One instance per process.** `shared` is the app's, and it is reached only through injection:
/// `IrisEngine(recentWrites:)`, threaded by `SubagentManager` and `GoalEvaluator` to the engines
/// they build, so a subagent's write lands in the same registry as its parent's. Tests build
/// their own over a fake clock and never touch `shared` (invariant 7).
///
/// **Only unattended writes are recorded** (R-D4-1). A write the user asked for in a foreground
/// turn is a human-driven action a watch is supposed to notice; filtering it would be a knob
/// nobody asked for, pointing the wrong way.
///
/// `isOwn` compares strings; the caller has already put the event path through
/// `IrisPaths.canonicalPath` (R-D4-5), the helper `record` uses, so a delete event — whose leaf is
/// gone — still resolves (through its parent) to the spelling recorded here.
actor RecentWrites {
    /// The process's registry. Never mutated from a test; injected everywhere else.
    static let shared = RecentWrites()

    /// A safety valve, not a policy. Eviction by count is a filter *bypass* — a run that writes
    /// more files than this would see its earliest files' events as somebody else's — so the
    /// number sits where no plausible burst reaches it. Anyone lowering it should know which way
    /// it fails (`RecentWritesTests.theValveHoldsTenThousand` spells the direction out).
    static let maxEntries = 10_000

    /// Entries older than this are dropped on every `record`. It is the longest expiry any caller
    /// can ask for — `min(300, 30) + 2` — so nothing live is ever swept.
    static let sweepAfter: TimeInterval = 32

    /// How long after a write its events still count as ours: the watch's quiet window, capped at
    /// 30 s because past that a write and an edit are no longer plausibly the same event, plus
    /// 2 s for FSEvents' 1 s stream latency and headroom. A stale entry swallowing a genuine hand
    /// edit minutes later is the failure that matters, so the cap is not negotiable per-watch.
    static func expiry(quietWindowSeconds: Int) -> TimeInterval {
        min(Double(quietWindowSeconds), 30) + 2
    }

    private struct Entry {
        let path: String
        let at: Date
    }

    /// In record order, which is time order: the clock is injected but only ever moves forward.
    /// A flat array rather than an index by path because `isOwn` asks three questions of each
    /// live entry (exact, parent, temp sibling) and only the first is a lookup; the scan runs
    /// newest-first and stops at the first entry outside the window, so it costs the live set,
    /// not the valve.
    private var entries: [Entry] = []
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    var count: Int { entries.count }

    /// Remember `path` as ours, in the spelling FSEvents will report it in.
    ///
    /// Symlink-resolved, and not merely `ToolExecutor.resolvePath`'s output: that one expands `~`
    /// and joins the workspace but leaves symlinks alone, and a watch root reached through one
    /// (`/tmp`, `/var`, a symlinked workspace) would then never match. Standardising also strips a
    /// leading `/private` on macOS, which is what makes a write under the temp directory record as
    /// `/var/folders/…` — the same normalisation the watch coordinator applies to the paths it is
    /// handed.
    ///
    /// `IrisPaths.canonicalPath` rather than a bare `resolvingSymlinksInPath()` (which is §4's
    /// literal expression, widened here): that one returns a path whose *leaf* does not exist
    /// unchanged, symlinked parents and all — measured, and already both documented and handled by
    /// the helper, which resolves the deepest existing ancestor and re-appends what is missing.
    /// `delete_skill` records a folder that has just gone, so without this the registry and
    /// `WatchRoot.canonical` would spell the same directory two ways. It ends in
    /// `standardizedFileURL`, so the recorded form is unchanged for a path that does exist.
    ///
    /// This is the one place in the registry that touches the file system; `isOwn` stays lexical.
    func record(_ path: String) {
        entries.append(Entry(path: IrisPaths.canonicalPath(path), at: now()))
        sweep()
    }

    /// Whether an event on `eventPath` is the echo of something recorded within `expiry`.
    ///
    /// A match is any of: the path itself; the *parent* of a recorded path, which is the
    /// directory-modified event every file write produces; or a sibling whose basename is one of
    /// Foundation's atomic-write temp forms, because `ToolExecutor.writeFile` writes atomically
    /// and each write leaves a temp file's create, rename and remove beside the final path.
    ///
    /// Entries are not consumed: one write produces several events, and it is expiry — never a
    /// match — that ends an entry's effect.
    func isOwn(_ eventPath: String, within expiry: TimeInterval) -> Bool {
        let cutoff = now().addingTimeInterval(-expiry)
        let eventBasename = (eventPath as NSString).lastPathComponent
        let eventParent = (eventPath as NSString).deletingLastPathComponent
        for entry in entries.reversed() {
            // Record order is time order, so the first entry outside the window ends the scan.
            guard entry.at > cutoff else { return false }
            if entry.path == eventPath { return true }
            let recordedParent = (entry.path as NSString).deletingLastPathComponent
            if recordedParent == eventPath { return true }
            if recordedParent == eventParent,
               Self.isAtomicTempSibling(eventBasename,
                                        of: (entry.path as NSString).lastPathComponent) {
                return true
            }
        }
        return false
    }

    /// Whether `basename` is one of the temp files an atomic write of `recorded` (a basename, not
    /// a path) leaves beside it. The same three forms the watch's built-in ignore set carries;
    /// they are spelled here as well because a temp file *in a watched folder* is ignored by the
    /// glob, while the question here is whose write it was.
    static func isAtomicTempSibling(_ basename: String, of recorded: String) -> Bool {
        // Foundation's staging file. Measured on macOS 26 (Darwin 25.6): `Data.write(options:
        // .atomic)` stages as `<name>.sb-<hex>-<rand>` with no leading dot; the dotted spelling is
        // kept for the releases that used it.
        if basename.hasPrefix("\(recorded).sb-") || basename.hasPrefix(".\(recorded).sb-") { return true }
        if basename == "\(recorded).tmp" { return true }
        if basename.hasPrefix("(A Document Being Saved By ") { return true }
        return false
    }

    /// Time first, then the valve. Both are here rather than in `isOwn` so the bound is on what is
    /// stored, not on what is asked.
    private func sweep() {
        let cutoff = now().addingTimeInterval(-Self.sweepAfter)
        if let firstLive = entries.firstIndex(where: { $0.at > cutoff }) {
            if firstLive > 0 { entries.removeFirst(firstLive) }
        } else {
            entries.removeAll()
        }
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }
}
