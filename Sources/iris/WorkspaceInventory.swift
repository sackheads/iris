import Foundation

/// One directory found directly under the goal-workspaces root (#126, Settings → Advanced).
///
/// Eligibility is by LOCATION, not a flag: `GoalWorkspace.resolve` confines creation to
/// `IrisPaths.workspacesDir`, so "a directory directly under that root" is exactly "created by
/// Iris" — a goal bound to an arbitrary path like `~/src/foo` is never listed here.
struct WorkspaceEntry: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let modifiedAt: Date?
    /// Nil until computed — `WorkspaceInventory.scan` never walks the tree; the UI computes this
    /// off-main via `directorySize` and publishes it back.
    let sizeBytes: Int64?
    let ownerConversationId: UUID?
    let ownerTitle: String?
    let ownerHasActiveGoal: Bool

    /// No conversation's `workspacePath` points at this directory.
    var isOrphan: Bool { ownerConversationId == nil }
}

/// The outcome of `AppState.deleteWorkspace`.
enum WorkspaceDeletion: Equatable {
    case trashed(URL)
    case refusedActiveGoal(title: String)
}

enum WorkspaceInventory {
    /// Lists the immediate subdirectories of `root` (files at the root are ignored) and matches
    /// each to an owning conversation by standardized path equality — tolerant of a `~`-expanded
    /// or trailing-slash variant on either side. Pure given its inputs: does not touch
    /// `AppState.shared` or any global, and never computes `sizeBytes` (see `directorySize`).
    static func scan(
        root: URL,
        conversations: [(id: UUID, title: String, workspacePath: String?, activeGoal: String?)],
        fileManager: FileManager = .default
    ) -> [WorkspaceEntry] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var ownerByPath: [String: (id: UUID, title: String, activeGoal: String?)] = [:]
        for c in conversations {
            guard let path = c.workspacePath, !path.isEmpty else { continue }
            ownerByPath[standardizedPath(path)] = (c.id, c.title, c.activeGoal)
        }

        var entries: [WorkspaceEntry] = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            let owner = ownerByPath[standardizedPath(url.path)]
            entries.append(WorkspaceEntry(
                url: url.standardizedFileURL,
                name: url.lastPathComponent,
                modifiedAt: values?.contentModificationDate,
                sizeBytes: nil,
                ownerConversationId: owner?.id,
                ownerTitle: owner?.title,
                ownerHasActiveGoal: owner?.activeGoal != nil
            ))
        }
        return entries
    }

    /// Sums allocated size over every file under `url`. Meant to be called from a background
    /// `Task` by the UI — never from `scan` — so a large workspace can't stall the settings list.
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// Tilde-expands, strips a trailing separator, and standardizes so `~/.iris/workspaces/foo`,
    /// `/Users/x/.iris/workspaces/foo/`, and the plain resolved path all compare equal.
    private static func standardizedPath(_ path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        if expanded.count > 1, expanded.hasSuffix("/") { expanded.removeLast() }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

extension FileManager {
    /// Wraps `trashItem(at:resultingItemURL:)` in the plain `(URL) throws -> Void` shape
    /// `AppState.deleteWorkspace`'s `trash:` parameter needs, so a test whose sandbox can't reach
    /// the real Trash can inject a substitute (e.g. a plain move) with the same signature.
    func trashItem(at url: URL) throws {
        var resultingURL: NSURL?
        try trashItem(at: url, resultingItemURL: &resultingURL)
    }
}
