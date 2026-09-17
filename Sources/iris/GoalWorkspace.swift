import Foundation

/// Where a contracted goal runs (#68).
enum WorkspaceResolution: Equatable {
    case existing(String)      // a directory that is already there
    case created(String)       // a fresh one to be made under ~/.iris/workspaces
    case keptExisting(String)  // the conversation was already bound; nothing changes
}

/// The decision rule for a goal's workspace, and the naming around it.
///
/// Everything here is pure — directory existence is injected — so the draft panel can display a
/// resolution without touching the filesystem. `.created` NAMES a path; it does not make one.
/// Creation happens once, at lock (spec §4.1).
enum GoalWorkspace {
    /// Resolve in order: an existing binding wins; then a proposal that exists; otherwise a fresh
    /// workspace under `workspacesRoot`.
    ///
    /// A proposal that does not exist is deliberately NOT an error — it falls back, and the panel
    /// shows the resolved path before the user approves, so the fallback is visible rather than
    /// silent. Creation is confined to `workspacesRoot` so a bad proposal can at worst name a
    /// directory the user already has; it can never cause one to appear somewhere new (spec §4).
    static func resolve(proposed: String?, objective: String, existingBinding: String?,
                        workspacesRoot: String,
                        directoryExists: (String) -> Bool) -> WorkspaceResolution {
        if let existingBinding, !existingBinding.isEmpty {
            return .keptExisting(existingBinding)
        }
        if let proposed, !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (proposed.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
                .expandingTildeInPath
            if directoryExists(expanded) { return .existing(expanded) }
        }
        let base = slug(for: objective)
        var candidate = "\(workspacesRoot)/\(base)"
        var n = 2
        while directoryExists(candidate) {
            candidate = "\(workspacesRoot)/\(base)-\(n)"
            n += 1
        }
        return .created(candidate)
    }

    /// A filesystem-safe directory name from a goal's objective.
    static func slug(for objective: String) -> String {
        var out = ""
        var lastWasSeparator = true   // suppresses a leading separator
        for ch in objective.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                out.append("-")
                lastWasSeparator = true
            }
            if out.count >= 40 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "goal" : out
    }

    /// True for workspaces worth warning about before the user approves: the Iris source tree
    /// itself (the literal complaint in #68), the home directory, and dotfile directories. This
    /// never blocks — working on Iris is legitimate; doing it silently is the bug (spec §5).
    static func isSensitive(_ path: String, homeDirectory: String, processCwd: String) -> Bool {
        let p = (path as NSString).standardizingPath
        if p == (processCwd as NSString).standardizingPath { return true }
        if p == (homeDirectory as NSString).standardizingPath { return true }
        let name = (p as NSString).lastPathComponent
        return name.hasPrefix(".")
    }
}
