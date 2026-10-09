import Foundation

/// What one watch fire saw and what it absorbed (#187 deliverable 4, spec §6): the figures the run
/// row, the event card, `get_job_run` and `/jobs` all read from. Stamped on the run the burst
/// started, so a person can tell a quiet watch from a busy one that is filtering well — a run that
/// reports `2 changes · 40 noise` is a watch doing its job, and one that reports forty changes is
/// an ignore list that needs a glob.
///
/// Counts are per burst, not since launch; the running totals a watch absorbed between bursts are
/// `AbsorbedCounts`, which lives in the coordinator's memory and is never persisted.
struct WatchSummary: Codable, Sendable, Equatable {
    /// Paths handed to the run. At most `changed`, and 0 when the guard withheld the block.
    var delivered: Int
    /// Distinct paths in the burst, kept or not.
    var changed: Int
    /// Distinct paths beyond the tracking bound: counted, not kept.
    var overflow: Int
    /// Accepted path entries as the watcher delivered them, before they were made distinct.
    var coalesced: Int
    /// Absorbed this burst by the built-in ignore set or the watch's own globs.
    var noise: Int
    /// Absorbed this burst because Iris's own unattended run wrote the file.
    var ownWrites: Int
    /// The burst never went quiet and was cut at `quietWindowSeconds × 10`.
    var ceilingFired: Bool
    /// The injection guard blocked the block of paths, so the run got none of them.
    var pathsWithheld: Bool

    init(delivered: Int = 0, changed: Int = 0, overflow: Int = 0, coalesced: Int = 0,
         noise: Int = 0, ownWrites: Int = 0, ceilingFired: Bool = false,
         pathsWithheld: Bool = false) {
        self.delivered = delivered
        self.changed = changed
        self.overflow = overflow
        self.coalesced = coalesced
        self.noise = noise
        self.ownWrites = ownWrites
        self.ceilingFired = ceilingFired
        self.pathsWithheld = pathsWithheld
    }

    private enum CodingKeys: String, CodingKey {
        case delivered, changed, overflow, coalesced, noise, ownWrites, ceilingFired, pathsWithheld
    }

    /// Invariant 1: every field is optional on the way in. A summary written by a build that knew
    /// fewer figures reads back with zeroes for the rest rather than costing the whole run row —
    /// the row's own facts (that it fired, what it cost, what came of it) matter more than the
    /// arithmetic of the burst.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delivered = try c.decodeIfPresent(Int.self, forKey: .delivered) ?? 0
        changed = try c.decodeIfPresent(Int.self, forKey: .changed) ?? 0
        overflow = try c.decodeIfPresent(Int.self, forKey: .overflow) ?? 0
        coalesced = try c.decodeIfPresent(Int.self, forKey: .coalesced) ?? 0
        noise = try c.decodeIfPresent(Int.self, forKey: .noise) ?? 0
        ownWrites = try c.decodeIfPresent(Int.self, forKey: .ownWrites) ?? 0
        ceilingFired = try c.decodeIfPresent(Bool.self, forKey: .ceilingFired) ?? false
        pathsWithheld = try c.decodeIfPresent(Bool.self, forKey: .pathsWithheld) ?? false
    }
}

extension WatchSummary {
    /// The figures a person reads, spelled once for the card, the `/jobs` watch line and the
    /// transcript: `12 changes · 3 noise · 1 own writes`, then the flags in parentheses. Each
    /// figure appears only when it is non-zero, and the whole is `nil` when there is nothing to
    /// say — a card for a burst that changed, filtered and withheld nothing reads exactly as an
    /// ordinary card does.
    ///
    /// The ceiling is `(cut at <ceilingSeconds> s)` when the caller knows the window and `(cut at
    /// the ceiling)` when it does not: the card carries no window, and a literal `30 s` printed
    /// from the default would be false for any watch with another one.
    func figuresText(ceilingSeconds: Int? = nil) -> String? {
        var figures: [String] = []
        if changed > 0 { figures.append("\(changed) changes") }
        if noise > 0 { figures.append("\(noise) noise") }
        if ownWrites > 0 { figures.append("\(ownWrites) own writes") }
        var text = figures.joined(separator: " · ")
        if ceilingFired {
            text += ceilingSeconds.map { " (cut at \($0) s)" } ?? " (cut at the ceiling)"
        }
        if overflow > 0 { text += " (\(overflow) not kept)" }
        if pathsWithheld { text += " (paths withheld by the guard)" }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What a watch has absorbed since the process started — every burst's filtered events plus the
/// ones that arrived while the job was paused (spec §2, §6). Memory only: it is a "how noisy is
/// this folder" figure for `/jobs`, not a record worth surviving a relaunch, and persisting it
/// would mean a write on every ignored `.DS_Store`.
struct AbsorbedCounts: Codable, Sendable, Equatable {
    var noise = 0
    var ownWrites = 0
    var whilePaused = 0
}
