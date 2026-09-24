import Foundation
import Darwin

/// Why a granted read or write did not happen, in the words the tool returns.
enum GrantedFileError: Error, Equatable {
    case emptyPath
    case badComponent(String)
    case rootUnavailable(String)        // the granted source no longer resolves (realpath failed)
    case symlink(component: String)
    case notADirectory(component: String)
    case isADirectory(component: String)
    case notARegularFile(component: String)
    case missing(component: String)
    case stagingExists(String)
    case io(call: String, errno: Int32)

    var message: String {
        switch self {
        case .emptyPath: return "a granted read or write needs a file name under the granted directory"
        case .badComponent(let component): return "the path component `\(component)` is not allowed under a grant; name the file with plain components under the granted directory"
        case .rootUnavailable(let root): return "the granted directory \(root) no longer exists"
        case .symlink(let component): return "the path crosses a symlink at `\(component)`; a granted run may not read or write through symlinks — name the real directory instead"
        case .notADirectory(let component): return "`\(component)` is not a directory"
        case .isADirectory(let component): return "`\(component)` is a directory, not a file"
        case .notARegularFile(let component): return "`\(component)` is not a regular file (a pipe, socket or device); a granted run reads regular files only"
        case .missing(let component): return "no such file or directory: `\(component)`"
        case .stagingExists(let name): return "a staging file `\(name)` already exists; try again"
        case .io(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// A granted run's file access (#282 §0.13). The allow (`JobGrant.allowedMount`) decides *whether*;
/// this decides *where* in a way nothing on the host can move between the two: the mount's root is
/// opened once as a directory descriptor, every remaining component is walked with `openat` and
/// `O_NOFOLLOW`, and a write is staged and renamed inside the final directory's descriptor. A
/// symlink anywhere in the remainder is a refusal, never followed — met as ENOTDIR on a directory
/// open (measured, remapped to `symlink` after an `fstatat`) or ELOOP on the final open.
///
/// `root` is the mount's *stored* spelling: `IrisPaths.canonicalPath` form, `/private` stripped, no
/// trailing slash. Step 2 of the root open compares the kernel's resolution, canonicalised, with
/// this string, so any other spelling is refused with a `symlink(component:)` sentence that names
/// an innocent component. One trailing slash is tolerated and stripped, because
/// `JobGrant.relativeComponents` tolerates the same one; the two must read the source alike.
struct GrantedFileAccess: Sendable {
    let root: String
    let stagingName: @Sendable (String) -> String

    init(root: String, stagingName: @escaping @Sendable (String) -> String = GrantedFileAccess.defaultStagingName) {
        self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        self.stagingName = stagingName
    }

    /// Foundation's own staging shape (measured on Darwin 25.6: `<name>.sb-<hex>-<rand>`), so the
    /// watches' sibling rule and the built-in ignore set treat it as the run's own write.
    static func defaultStagingName(_ name: String) -> String {
        "\(name).sb-\(String(UInt32.random(in: .min ... .max), radix: 16))-\(String(UInt32.random(in: .min ... .max), radix: 36))"
    }

    func read(relative: [String]) throws -> String {
        guard let name = relative.last else { throw GrantedFileError.emptyPath }
        try Self.validate(relative)
        let rootFD = try openRoot()
        defer { close(rootFD) }
        let dirFD = try descend(relative.dropLast(), from: rootFD)
        defer { if dirFD != rootFD { close(dirFD) } }
        // `O_NONBLOCK` so a FIFO cannot park the run before it is refused: a plain `open(O_RDONLY)`
        // of a pipe blocks until a writer appears (measured by review). The descriptor is asked what
        // it is, only a regular file is read, and the flag is cleared for the read itself.
        let fd = openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.error(errno, at: name, call: "openat") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw GrantedFileError.io(call: "fstat", errno: errno) }
        if (st.st_mode & S_IFMT) == S_IFDIR { throw GrantedFileError.isADirectory(component: name) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw GrantedFileError.notARegularFile(component: name) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { throw GrantedFileError.io(call: "read", errno: errno) }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        guard let text = String(data: data, encoding: .utf8) else { throw GrantedFileError.io(call: "decode", errno: EILSEQ) }
        return text
    }

    func write(relative: [String], content: String) throws {
        guard let name = relative.last else { throw GrantedFileError.emptyPath }
        try Self.validate(relative)
        let rootFD = try openRoot()
        defer { close(rootFD) }
        let dirFD = try descend(relative.dropLast(), from: rootFD)
        defer { if dirFD != rootFD { close(dirFD) } }
        // `renameat` would replace a symlink rather than follow it, but a run may not write
        // *through* one either way (§0.13): refuse before anything is staged.
        var st = stat()
        if fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK { throw GrantedFileError.symlink(component: name) }
            if (st.st_mode & S_IFMT) == S_IFDIR { throw GrantedFileError.isADirectory(component: name) }
        }
        let staging = stagingName(name)
        let fd = openat(dirFD, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw errno == EEXIST ? GrantedFileError.stagingExists(staging) : Self.error(errno, at: staging, call: "openat")
        }
        var renamed = false
        defer {
            close(fd)
            if !renamed { _ = unlinkat(dirFD, staging, 0) }
        }
        let bytes = Array(content.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress! + written, $0.count - written) }
            guard n > 0 else { throw GrantedFileError.io(call: "write", errno: errno) }
            written += n
        }
        guard fsync(fd) == 0 else { throw GrantedFileError.io(call: "fsync", errno: errno) }
        guard renameat(dirFD, staging, dirFD, name) == 0 else { throw GrantedFileError.io(call: "renameat", errno: errno) }
        renamed = true
    }

    // MARK: - The walk

    /// The walk's own gate, before any syscall: `..` is a real directory entry the kernel opens
    /// without complaint (measured), `.` and "" are no-ops that would hide a mistake, and a `/`
    /// inside a component is a path pretending to be a name. The executor hands this the
    /// post-hook path, so nothing upstream is relied on.
    private static func validate(_ relative: [String]) throws {
        for component in relative where component.isEmpty || component == "." || component == ".." || component.contains("/") {
            throw GrantedFileError.badComponent(component)
        }
    }

    /// The root, in three steps (§0.13). Not `open(root)`: a nested entry's ancestors lie inside a
    /// read-write mount a command can rename, and `open` follows them (measured). Not an
    /// `O_NOFOLLOW` walk of the stored spelling either: `/tmp`, `/var`, `/etc` are symlinks into
    /// `/private`, and the stored form (`IrisPaths.canonicalPath`) strips `/private`, so that walk
    /// refused every grant under them at `tmp`/`var` (measured).
    ///
    /// (1) `realpath(3)` of the stored source — the kernel's resolution; (2) its canonical form
    /// must be the stored source again (`/private/tmp/x` → `/tmp/x`), which a root with a swapped
    /// component cannot satisfy (`…/mount/inner/leaf` with `inner → /etc` resolves to `/etc/…`);
    /// (3) the real path is walked from `/` with `O_NOFOLLOW` — it has no symlinks by definition,
    /// so one met here is a swap since step 1 and is refused. The window between (1) and (3)
    /// closes shut, never open.
    private func openRoot() throws -> Int32 {
        guard let resolved = Darwin.realpath(root, nil) else { throw GrantedFileError.rootUnavailable(root) }
        let real = String(cString: resolved)
        free(resolved)
        guard IrisPaths.canonicalPath(real) == root else {
            throw GrantedFileError.symlink(component: firstSwappedComponent())
        }
        let components = real.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        try Self.validate(components)
        let slash = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard slash >= 0 else { throw GrantedFileError.io(call: "open", errno: errno) }
        return try descend(components[...], from: slash, closingRoot: true)
    }

    /// For the sentence only, on the failure path of step 2: the first prefix of the stored root
    /// whose kernel resolution no longer canonicalises to its own spelling — `…/mount/inner` for a
    /// swapped `inner`, the root itself for a root that became a link. System symlinks pass
    /// (`/var` → `/private/var` → canonical `/var`).
    private func firstSwappedComponent() -> String {
        var prefix = ""
        for component in root.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            prefix += "/" + component
            guard let resolved = Darwin.realpath(prefix, nil) else { return component }
            let real = String(cString: resolved)
            free(resolved)
            if IrisPaths.canonicalPath(real) != prefix { return component }
        }
        return (root as NSString).lastPathComponent
    }

    /// Opens each directory component in turn, each relative to the one before, none through a
    /// symlink. Returns the final directory's descriptor (the starting one when there is none).
    /// `closingRoot` closes the starting descriptor once it has been advanced past (the root walk);
    /// the caller-owned root descriptor of a read/write is never closed here.
    private func descend(_ directories: ArraySlice<String>, from start: Int32, closingRoot: Bool = false) throws -> Int32 {
        var dirFD = start
        for component in directories {
            let next = openat(dirFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            let failure: GrantedFileError? = next >= 0 ? nil : Self.directoryError(code, in: dirFD, at: component)
            if dirFD != start || closingRoot { close(dirFD) }
            if let failure { throw failure }
            dirFD = next
        }
        return dirFD
    }

    /// Measured (macOS 26): a directory open of a symlink with `O_NOFOLLOW` fails with ENOTDIR, not
    /// ELOOP, so the entry is asked what it is before the sentence is chosen.
    private static func directoryError(_ code: Int32, in dirFD: Int32, at component: String) -> GrantedFileError {
        if code == ENOTDIR || code == ELOOP {
            var st = stat()
            if fstatat(dirFD, component, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                return .symlink(component: component)
            }
            return .notADirectory(component: component)
        }
        return error(code, at: component, call: "openat")
    }

    private static func error(_ code: Int32, at component: String, call: String) -> GrantedFileError {
        switch code {
        case ELOOP: return .symlink(component: component)
        case ENOTDIR: return .notADirectory(component: component)
        case ENOENT: return .missing(component: component)
        default: return .io(call: call, errno: code)
        }
    }
}
