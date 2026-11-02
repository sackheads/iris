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
        return [spelled, IrisPaths.realPath(spelled)].contains { candidate in
            candidate.split(separator: "/").contains { $0.lowercased() == name }
        }
    }
}
