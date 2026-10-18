import Foundation

/// A workspace's own `.iris/` (#617): Vibecop's rules (`vibecop.md`), the project allowlist
/// (`permissions.json`) and the sandbox override (`sandbox.json`). They steer what Iris lets run,
/// so nothing the agent can do without a person may change them.
///
/// In the VM, the workspace is mounted read-write and `.iris/` over it read-only, which the
/// runtime enforces against every write, rename, chmod and link (probed on CLI 1.1.0). A read-only
/// mount does not cover links that were already there, which a repository can carry: a symlink
/// or a second hard link to a file outside `.iris/` is written through that other name. So Iris
/// reads these files only as regular files with one link, in a real `.iris/` directory, opened
/// without following a link and checked on the descriptor it reads. On the host, a model or tool
/// write into a workspace `.iris/` always asks a person (`AppState.requestApprovalSource`).
enum WorkspaceIrisDir {
    static let name = ".iris"

    /// Contents of `<workspace>/.iris/<file>`, or nil when it is missing or is not a file Iris
    /// trusts: a symlink, a hard-linked file, anything but a regular file, or a `.iris` that is
    /// itself a link or not a directory.
    static func read(_ file: String, workspace: String) -> Data? {
        let dir = (IrisEngine.expandTilde(workspace) as NSString).appendingPathComponent(name)
        let dirFD = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { return nil }
        defer { close(dirFD) }
        // `O_NONBLOCK`: a FIFO planted while the VM could still write here would block the open,
        // on the approval path, for good (#625 review). The fstat below refuses it.
        let fd = openat(dirFD, file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { return nil }
        return try? handle.readToEnd() ?? Data()
    }

    enum Prepared: Equatable {
        /// `.iris/` is a real directory at this host path, ready to mount read-only.
        case ready(String)
        /// It cannot be protected, and why.
        case refused(String)
    }

    /// Makes `<dir>/.iris` a directory the VM can be given read-only, before the container that
    /// mounts `dir` is created. Created empty when missing, so the VM cannot create it (#617).
    static func prepareForMount(_ dir: String) -> Prepared {
        let path = (dir as NSString).appendingPathComponent(name)
        var info = stat()
        // No workspace, nothing to protect: the container's own bind of it fails on its own.
        if lstat(dir, &info) != 0, errno == ENOENT { return .ready(path) }
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { return .refused(refusal(path, "it cannot be read")) }
            guard mkdir(path, 0o755) == 0 || errno == EEXIST else { return .refused(refusal(path, "it could not be created")) }
            guard lstat(path, &info) == 0 else { return .refused(refusal(path, "it cannot be read")) }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            return .refused(refusal(path, (info.st_mode & S_IFMT) == S_IFLNK ? "it is a symbolic link" : "it is not a directory"))
        }
        return .ready(path)
    }

    /// The read-only mount of `source`'s `.iris/` at `target`'s, in `ContainerMount`'s
    /// `source:target:ro` form. Listed after the mount it sits inside.
    static func mountEntry(source: String, target: String) -> String {
        "\((source as NSString).appendingPathComponent(name)):\((target as NSString).appendingPathComponent(name)):ro"
    }

    /// Whether a model or tool write to `path` lands in a workspace's `.iris/`: any `.iris`
    /// component outside Iris's own homes, which have rules of their own.
    static func isWorkspaceIrisPath(_ path: String, homes: [String]) -> Bool {
        let resolved = IrisEngine.expandTilde(path)
        if homes.contains(where: { resolved == $0 || resolved.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { return false }
        // Case-insensitively: APFS is, so `.IRIS` is the same folder (#625 review).
        return resolved.split(separator: "/").contains { $0.lowercased() == name }
    }

    /// Whether a host command names a `.iris` other than Iris's own home, after removing the quotes
    /// and backslashes the shell would. Best effort: a command can reach a path it does not spell
    /// (a glob, a script), which is why the VM's side is a mount and not this.
    static func commandNamesWorkspaceIris(_ command: String) -> Bool {
        let plain = command.filter { $0 != "'" && $0 != "\"" && $0 != "\\" }.lowercased()
        var rest = Substring(plain)
        while let range = rest.range(of: name) {
            let before = rest[..<range.lowerBound]
            let after = rest[range.upperBound...]
            let homeSpelling = before.hasSuffix("~/") || before.hasSuffix("home/") || before.hasSuffix("home}/")
            let isWord = after.first.map { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } ?? true
            if !homeSpelling && isWord { return true }
            rest = after
        }
        return false
    }

    private static func refusal(_ path: String, _ why: String) -> String {
        "Not run: the workspace's \(name) folder (\(path)) cannot be protected from the sandbox because \(why). It holds Vibecop's rules and the project allowlist; fix or remove it, then try again."
    }
}
