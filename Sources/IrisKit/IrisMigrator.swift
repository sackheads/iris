import Foundation

/// One-shot migration of an old flat `~/.iris` layout to the segregated
/// `memory/` + `config/` + `models/` layout.
///
/// Idempotent and non-destructive: each file moves only if the source exists and the
/// destination does not, so re-runs and partially-migrated installs are safe. The one
/// sanctioned deletion is the redundant stray `~/.iris/SOUL.md` (the never-read copy), removed
/// only once the canonical `memory/SOUL.md` is in place. Must run before any manager opens a
/// migrated file (notably the holographic SQLite DB — moving an open WAL database corrupts it).
enum IrisMigrator {
    static func migrate(_ paths: IrisPaths) {
        let fm = FileManager.default
        try? paths.ensureDirectories()
        let root = paths.root

        // memory/ files
        moveIfNeeded(fm, from: root.appendingPathComponent("USER.md"), to: paths.userMd)
        moveIfNeeded(fm, from: root.appendingPathComponent("memory.md"), to: paths.memoryMd)
        moveIfNeeded(fm, from: root.appendingPathComponent("skills"), to: paths.skillsDir)
        moveIfNeeded(fm, from: root.appendingPathComponent("library"), to: paths.artifactsDir)

        // holographic DB + WAL sidecars
        moveIfNeeded(fm, from: root.appendingPathComponent("holographic_memory.sqlite"), to: paths.holographicDB)
        moveIfNeeded(fm, from: root.appendingPathComponent("holographic_memory.sqlite-shm"),
                     to: paths.memoryDir.appendingPathComponent("holographic_memory.sqlite-shm"))
        moveIfNeeded(fm, from: root.appendingPathComponent("holographic_memory.sqlite-wal"),
                     to: paths.memoryDir.appendingPathComponent("holographic_memory.sqlite-wal"))

        // config/ files
        moveIfNeeded(fm, from: root.appendingPathComponent("settings.json"), to: paths.settingsJSON)
        moveIfNeeded(fm, from: root.appendingPathComponent("permissions.json"), to: paths.permissionsJSON)
        moveIfNeeded(fm, from: root.appendingPathComponent("mcp_servers.json"), to: paths.mcpServersJSON)

        // SOUL: the actively-read prompts/SOUL.md is canonical; the stray root SOUL.md is the
        // redundant never-read copy and is deleted once the canonical one exists.
        moveIfNeeded(fm, from: root.appendingPathComponent("prompts/SOUL.md"), to: paths.soulMd)
        let straySoul = root.appendingPathComponent("SOUL.md")
        if fm.fileExists(atPath: paths.soulMd.path), fm.fileExists(atPath: straySoul.path) {
            try? fm.removeItem(at: straySoul)
        }
    }

    /// Move source to destination — idempotent and never overwrites an already-migrated item.
    ///
    /// - File source: moved only when destination does not already exist.
    /// - Directory source: destination is ensured, then contents are merged item-by-item
    ///   (recursive, non-destructive). The source directory is removed only once fully drained.
    ///   A collision leaves the source item in place so that the next `migrate()` call can
    ///   retry — satisfying the crash-safe / re-runnable guarantee.
    private static func moveIfNeeded(_ fm: FileManager, from: URL, to: URL) {
        var fromIsDir: ObjCBool = false
        guard fm.fileExists(atPath: from.path, isDirectory: &fromIsDir) else { return }

        if fromIsDir.boolValue {
            // Ensure the destination directory exists (it may have been pre-created by ensureDirectories).
            try? fm.createDirectory(at: to, withIntermediateDirectories: true)
            mergeDirectory(fm, from: from, into: to)
            // Remove source only if fully drained.
            let remaining = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)
            if remaining?.isEmpty == true {
                try? fm.removeItem(at: from)
            }
        } else {
            // File: skip if destination already exists (non-destructive).
            guard !fm.fileExists(atPath: to.path) else { return }
            try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: from, to: to)
        }
    }

    /// Recursively merge the contents of `from` into `into`, item-by-item, non-destructively.
    ///
    /// For each item in `from`:
    /// - If no destination item exists: move it.
    /// - If both source and destination are directories: recurse (merge subtrees).
    /// - If destination already has a file of that name: leave source item untouched (collision).
    private static func mergeDirectory(_ fm: FileManager, from: URL, into: URL) {
        guard let items = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items {
            let dest = into.appendingPathComponent(item.lastPathComponent)
            var srcIsDir: ObjCBool = false
            var dstIsDir: ObjCBool = false
            let srcExists = fm.fileExists(atPath: item.path, isDirectory: &srcIsDir)
            let dstExists = fm.fileExists(atPath: dest.path, isDirectory: &dstIsDir)
            guard srcExists else { continue }

            if !dstExists {
                // Destination slot is free — move directly.
                try? fm.moveItem(at: item, to: dest)
            } else if srcIsDir.boolValue && dstIsDir.boolValue {
                // Both are directories — recurse to merge subtrees.
                mergeDirectory(fm, from: item, into: dest)
                let remaining = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
                if remaining?.isEmpty == true {
                    try? fm.removeItem(at: item)
                }
            }
            // else: destination file exists and source is a file — leave in place (collision).
        }
    }
}
