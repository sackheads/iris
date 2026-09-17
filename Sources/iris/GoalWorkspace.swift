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
        // Bounded: the draft panel calls this on every keystroke, on the main thread, so an
        // unbounded scan would hang the UI rather than merely be slow. After a sane number of
        // tries, fall back to a name that cannot collide.
        for n in 2...99 {
            if !directoryExists(candidate) { return .created(candidate) }
            candidate = "\(workspacesRoot)/\(base)-\(n)"
        }
        if directoryExists(candidate) {
            candidate = "\(workspacesRoot)/\(base)-\(UUID().uuidString.prefix(8).lowercased())"
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
    /// Symlinks are resolved on BOTH sides: `standardizingPath` collapses `.`/`..` but follows no
    /// links, so a symlink whose target is the source tree would otherwise slip past the one
    /// warning that exists to stop a silent re-run of #68.
    static func isSensitive(_ path: String, homeDirectory: String, processCwd: String) -> Bool {
        func canonical(_ s: String) -> String {
            ((s as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        }
        let p = canonical(path)
        if p == canonical(processCwd) { return true }
        if p == canonical(homeDirectory) { return true }
        // Checked on the ORIGINAL path too: a link named `.secrets` is worth flagging even when
        // its target is not.
        let names = [(p as NSString).lastPathComponent,
                     ((path as NSString).standardizingPath as NSString).lastPathComponent]
        return names.contains { $0.hasPrefix(".") }
    }
}

extension GoalWorkspace {
    /// A one-line warning for a workspace worth a second look, or nil. Never blocks (spec §5).
    static func warningText(for path: String, homeDirectory: String, processCwd: String) -> String? {
        guard isSensitive(path, homeDirectory: homeDirectory, processCwd: processCwd) else { return nil }
        let p = (path as NSString).standardizingPath
        if p == (processCwd as NSString).standardizingPath {
            return "This is the Iris source tree. The goal's files will land in Iris's own repository, and checks will run against it."
        }
        if p == (homeDirectory as NSString).standardizingPath {
            return "This is your home directory. The goal will be able to read and write anything in it."
        }
        return "This is a hidden configuration directory. Make sure the goal is meant to change it."
    }
}
