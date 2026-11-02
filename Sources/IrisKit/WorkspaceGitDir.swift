import Foundation

/// A `.git` in a workspace is code the person's next `git` command runs: hooks, and the programs a
/// repository's config names (`core.fsmonitor`, `core.sshCommand`, `core.pager`, `alias.*` that start
/// with `!`, `core.hooksPath`). The VM sees the mount's `.git/hooks` read-only (#623), but a granted
/// job's `write_file` runs on the host, where nothing stood in front of those files (#867).
enum WorkspaceGitDir {
    static let name = ".git"

    /// Whether writing `path` lands in a `.git` anywhere under it: a `.git` component in the path as
    /// spelled or in its real path (a link into a `.git` must not hide it), in a nested repository
    /// as much as at the mount's root, and a `.git` that is a file (a worktree's gitdir pointer) as
    /// much as a directory. Case-insensitive: APFS is, so `.GIT` is the same folder.
    static func isGitPath(_ path: String, cwd: String?) -> Bool {
        let spelled = ToolExecutor.resolvePath(path, cwd: cwd)
        let real = IrisPaths.realPath(spelled)
        return [spelled, real].contains { candidate in
            candidate.split(separator: "/").contains { $0.lowercased() == name }
        } || insideGitDirByStructure(real)
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
}
