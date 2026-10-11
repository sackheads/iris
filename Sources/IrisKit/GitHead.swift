import Foundation

struct GitProject: Equatable, Sendable {
    let repo: String
    let branch: String?
}

/// #469 §4.1: the repo and branch a session's workspace sits in, read from `.git` files at list
/// time. No `git` process: a listing reads one of these per peer, and a spawn per row would cost
/// more than the listing itself.
///
/// #480 review item 3 hardened every read here: `lstat`, not `stat` or `FileManager.fileExists`,
/// which follow symlinks — a `.git` or `HEAD` that is a symlink (to `/dev/zero`, to a FIFO, to
/// anywhere) is skipped rather than opened. Only a regular file (or, for `.git` itself, a plain
/// directory) is read, and never with `String(contentsOf:)`: that has no size cap and a `gitdir:`
/// line can point anywhere, including an iCloud or network mount, so each read is capped at 4 KB
/// through `FileHandle`. A symlinked `.git` is a dead end: the walk returns nil there rather than
/// continuing upward, so a workspace sitting under an unrelated outer repo is never credited with
/// it.
enum GitHead {
    static let maxDepth = 32
    private static let maxReadBytes = 4096

    /// `lstat`s `url`; reads at most `maxReadBytes` when it names a regular file that is not a
    /// symlink. Nil for anything else (symlink, directory, FIFO, socket, missing) — a `.git` or
    /// `HEAD` of any other kind is treated as absent, not opened.
    private static func readBoundedRegularFile(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxReadBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func read(workspace: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> GitProject? {
        var dir = URL(fileURLWithPath: workspace).standardizedFileURL
        let start = dir
        let home = homeDirectory.standardizedFileURL
        for _ in 0..<maxDepth {
            // A dotfiles repo at $HOME would otherwise claim every workspace below it: the walk
            // reaches home on its way up from anywhere, and home almost always has its own `.git`
            // for dotfiles rather than the user's actual project. Stop before inspecting home's
            // `.git` unless the workspace IS home.
            if dir.path == home.path, dir.path != start.path { return nil }
            let dotGit = dir.appendingPathComponent(".git")
            var info = stat()
            if lstat(dotGit.path, &info) == 0 {
                let mode = info.st_mode & S_IFMT
                if mode == S_IFDIR {
                    return GitProject(repo: dir.lastPathComponent, branch: branch(gitDir: dotGit))
                }
                if mode == S_IFREG {
                    // A worktree or a submodule: `.git` is a file naming its git dir —
                    // `<main>/.git/worktrees/<name>` or `<main>/.git/modules/<submodule>`.
                    guard let text = readBoundedRegularFile(dotGit),
                          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let gitDir = URL(fileURLWithPath: path, relativeTo: dir).standardizedFileURL
                    let parts = gitDir.pathComponents
                    // #480 review item 6: a submodule's gitdir lives under the SUPERPROJECT's
                    // `.git/modules/`, so naming it from `gitDir`'s own path (as the worktree case
                    // below does) would label it with the superproject's directory name instead
                    // of the submodule's own. The workspace's own directory — `dir`, which is the
                    // submodule's checkout, the one containing this `.git` file — is the right name.
                    let repo: String
                    if gitDir.path.contains("/.git/modules/") {
                        repo = dir.lastPathComponent
                    } else {
                        repo = parts.lastIndex(of: ".git").flatMap { $0 > 0 ? parts[$0 - 1] : nil } ?? dir.lastPathComponent
                    }
                    return GitProject(repo: repo, branch: branch(gitDir: gitDir))
                }
                // A symlink, FIFO, socket, or anything else: not a `.git` this walk can trust, and
                // a dead end rather than something to walk past — continuing upward could credit
                // this workspace with an unrelated repo that happens to sit further up the tree.
                return nil
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }

    private static func branch(gitDir: URL) -> String? {
        guard let head = readBoundedRegularFile(gitDir.appendingPathComponent("HEAD"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        if head.count >= 7, head.allSatisfy(\.isHexDigit) { return "detached@" + head.prefix(7) }
        return nil
    }
}
