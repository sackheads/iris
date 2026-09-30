import Foundation

/// Everything `register_directory_watcher` accepts (#187 deliverable 4, spec §5; grant fields
/// #282 §4), read once into the shape `ToolExecutor.registerWatcher` stores.
///
/// The three original optional arguments are `nil` when not given, and `nil` means "say nothing":
/// on a re-registration the stored value stands, and on a new watch the default applies. That is
/// why the window is not clamped here — the tool clamps it and says so, and a clamp is only worth
/// saying when a number was actually asked for. The grant (`mounts`, `network`) is the exception
/// to that rule (§0.1): a re-registration stores exactly the grant the call names, and naming none
/// removes the one that was stored. `profile` follows the original rule — omitted, the stored one
/// stands (`ToolExecutor.registerWatcher`: `asked ?? existing?.profile`).
struct RegisterWatcherArguments: Equatable, Sendable {
    let path: String
    let instructions: String
    let quietWindowSeconds: Int?
    let ignore: [String]?
    let overlap: JobPolicy.Overlap?
    let profile: String?
    let mounts: [String]?
    let network: Bool?
    /// #283. Follows the original rule, not the grant's: omitted on a re-registration leaves the
    /// stored figure alone, and omitted on a new watch takes the watch default rather than the
    /// scheduled-job one.
    let maxRunsPerHour: Int?

    static let missing: ToolMessage = "Error: Missing path or instructions"
    static let windowShape: ToolMessage = "Error: quiet_window_seconds must be a whole number of seconds (1 to 300)."
    static let ignoreShape: ToolMessage = "Error: ignore must be a list of glob patterns, e.g. [\"*.log\", \"build/\"]."
    static let runsShape: ToolMessage = "Error: max_runs_per_hour must be a whole number of runs, not a fraction (0 means no breaker at all)."

    /// Reads the tool call's arguments. A malformed optional argument is a refusal, not a drop
    /// (invariant 1's leniency is about *shape*, not about guessing): an `ignore` that was sent as
    /// one string and quietly dropped would create a watch that fires on exactly the files the
    /// model asked it to ignore, and nothing in the answer would say so. `schedule_job` refuses a
    /// malformed `overlap` for the same reason and its sentence is reused here.
    static func parse(_ args: [String: JSONValue]) -> Result<RegisterWatcherArguments, ToolMessage> {
        guard let path = ScheduleJobArguments.text(args["path"]),
              let instructions = ScheduleJobArguments.text(args["instructions"]) else {
            return .failure(missing)
        }
        var window: Int?
        if ScheduleJobArguments.given(args["quiet_window_seconds"]) != nil {
            guard let value = ScheduleJobArguments.integer(args["quiet_window_seconds"]) else {
                return .failure(windowShape)
            }
            window = value
        }
        var ignore: [String]?
        if ScheduleJobArguments.present(args["ignore"]) {
            guard case .array(let items) = args["ignore"] else { return .failure(ignoreShape) }
            var patterns: [String] = []
            for item in items {
                guard let pattern = ScheduleJobArguments.text(item) else { return .failure(ignoreShape) }
                patterns.append(pattern)
            }
            ignore = patterns
        }
        var overlap: JobPolicy.Overlap?
        if let asked = ScheduleJobArguments.given(args["overlap"]) {
            guard let word = ScheduleJobArguments.text(asked),
                  let value = JobPolicy.Overlap(rawValue: word.lowercased()) else {
                return .failure(ToolMessage("Error: " + ScheduleJobArguments.overlapShape.text))
            }
            overlap = value
        }
        let mounts: [String]?
        switch ScheduleJobArguments.stringList(args["mounts"], shape: ScheduleJobArguments.mountsShape) {
        case .failure(let message): return .failure(ToolMessage("Error: " + message.text))
        case .success(let values): mounts = values
        }
        let network: Bool?
        switch ScheduleJobArguments.boolean(args["network"]) {
        case .failure(let message): return .failure(ToolMessage("Error: " + message.text))
        case .success(let value): network = value
        }
        var runsPerHour: Int?
        if ScheduleJobArguments.given(args["max_runs_per_hour"]) != nil {
            // `exactInteger`, so 0.5 is refused rather than rounded to 0 — which would remove the
            // breaker without a word (review).
            guard let value = ScheduleJobArguments.exactInteger(args["max_runs_per_hour"]), value >= 0 else {
                return .failure(runsShape)
            }
            runsPerHour = value
        }
        return .success(RegisterWatcherArguments(
            path: path, instructions: instructions, quietWindowSeconds: window, ignore: ignore, overlap: overlap,
            profile: ScheduleJobArguments.text(args["profile"]), mounts: mounts, network: network,
            maxRunsPerHour: runsPerHour))
    }
}
