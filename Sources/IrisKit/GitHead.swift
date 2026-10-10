import Foundation

struct GitProject: Equatable, Sendable {
    let repo: String
    let branch: String?
}

/// #469 §4.1: the repo and branch a session's workspace sits in, read from `.git` files at list
/// time. No `git` process: a listing reads one of these per peer, and a spawn per row would cost
/// more than the listing itself.
enum GitHead {
    static let maxDepth = 32

    static func read(workspace: String, fileManager: FileManager = .default) -> GitProject? {
        var dir = URL(fileURLWithPath: workspace).standardizedFileURL
        for _ in 0..<maxDepth {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return GitProject(repo: dir.lastPathComponent, branch: branch(gitDir: dotGit))
                }
                // A worktree: `.git` is a file naming its git dir, `<main>/.git/worktrees/<name>`.
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = URL(fileURLWithPath: path, relativeTo: dir).standardizedFileURL
                let parts = gitDir.pathComponents
                let repo = parts.lastIndex(of: ".git").flatMap { $0 > 0 ? parts[$0 - 1] : nil } ?? dir.lastPathComponent
                return GitProject(repo: repo, branch: branch(gitDir: gitDir))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }

    private static func branch(gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        if head.count >= 7, head.allSatisfy(\.isHexDigit) { return "detached@" + head.prefix(7) }
        return nil
    }
}
