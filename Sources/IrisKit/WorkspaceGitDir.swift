import Foundation

/// A `.git` in a workspace is code the person's next `git` command runs: hooks, and the programs a
/// repository's config names (`core.fsmonitor`, `core.sshCommand`, `core.pager`, `alias.*` that start
/// with `!`, `core.hooksPath`). The VM sees the mount's `.git/hooks` read-only (#623), but a granted
/// job's `write_file` runs on the host, where nothing stood in front of those files (#867).
enum WorkspaceGitDir {
    static let name = ".git"

    /// The files a git dir runs as code once it is used: `config` and `HEAD` themselves, and
    /// anything one level under `hooks/` or `info/` (#907). A write to one of these is refused
    /// whenever its folder already has `objects/` or `refs/` — the shape a git dir takes on before
    /// it has a `HEAD`, so a planted request cannot complete the illusion by writing `config` and
    /// `HEAD` before the only check that existed (`insideGitDirByStructure`, which needs all three)
    /// could see it.
    private static let completingFiles: Set<String> = ["config", "head"]
    private static let completingParents: Set<String> = ["hooks", "info"]

    /// Whether writing `path` lands in a `.git` anywhere under it: a `.git` component in the path as
    /// spelled or in its real path (a link into a `.git` must not hide it), in a nested repository
    /// as much as at the mount's root, and a `.git` that is a file (a worktree's gitdir pointer) as
    /// much as a directory. Case-insensitive: APFS is, so `.GIT` is the same folder.
    static func isGitPath(_ path: String, cwd: String?) -> Bool {
        let spelled = ToolExecutor.resolvePath(path, cwd: cwd)
        let real = IrisPaths.realPath(spelled)
        return [spelled, real].contains { candidate in
            candidate.split(separator: "/").contains { $0.lowercased() == name }
        } || insideGitDirByStructure(real) || completesGitDirShape(real)
    }

    /// A git dir is not always named `.git`: a bare repository (`x.git/`, or any name) and the
    /// separate dir a `.git` gitfile points at (`store/real/`) hold the same hooks and config. An
    /// ancestor of the real path that has a `HEAD` file and `objects/` and `refs/` folders is one
    /// (the shape `ParentMount` finds a bare repository by); a plain folder named `a.git` is not.
    private static func insideGitDirByStructure(_ realPath: String) -> Bool {
        let fm = FileManager.default
        var dir = (realPath as NSString).deletingLastPathComponent
        while dir != "/" && !dir.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir + "/HEAD", isDirectory: &isDir), !isDir.boolValue,
               fm.fileExists(atPath: dir + "/objects", isDirectory: &isDir), isDir.boolValue,
               fm.fileExists(atPath: dir + "/refs", isDirectory: &isDir), isDir.boolValue { return true }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return false
    }

    /// #907: `path` is `config`, `HEAD`, or one level under `hooks/` or `info/`, in a folder that
    /// already has `objects/` or `refs/` (either one, neither required to be complete). That folder
    /// need not have a `HEAD` yet — unlike `insideGitDirByStructure`, which only ever sees a
    /// finished repository — because the finding this closes is exactly a write landing before HEAD
    /// does.
    private static func completesGitDirShape(_ realPath: String) -> Bool {
        let file = (realPath as NSString).lastPathComponent.lowercased()
        let parent = (realPath as NSString).deletingLastPathComponent
        let parentName = (parent as NSString).lastPathComponent.lowercased()
        let grandparent = (parent as NSString).deletingLastPathComponent

        let candidateDir: String
        if completingFiles.contains(file) {
            candidateDir = parent
        } else if completingParents.contains(parentName) {
            candidateDir = grandparent
        } else {
            return false
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        let hasObjects = fm.fileExists(atPath: candidateDir + "/objects", isDirectory: &isDir) && isDir.boolValue
        let hasRefs = fm.fileExists(atPath: candidateDir + "/refs", isDirectory: &isDir) && isDir.boolValue
        return hasObjects || hasRefs
    }
}
