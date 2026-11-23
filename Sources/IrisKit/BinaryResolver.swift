import Foundation

/// Resolves MCP server commands to absolute executable paths. GUI apps do not inherit the
/// user's shell PATH, so a bare command like `notebooklm-mcp` is resolved against the login
/// shell's PATH (captured once per launch) plus the common install locations. Iris never
/// installs runtimes itself.
enum BinaryResolver {
    /// Login-shell PATH entries, captured once per process. Falls back to empty on any failure.
    ///
    /// Not a `static let`: that initializer spawned a login shell and waited with
    /// `waitUntilExit()`, which pumps the main run loop, so on the main thread SwiftUI re-entered
    /// a sidebar row's body mid-initialisation, touched the still-initialising static again and
    /// died on libdispatch's non-reentrant once lock (#1001). The capture now waits on a
    /// semaphore, which pumps nothing, behind a plain lock, and `warmUp()` runs it off the main
    /// thread before the first window is built.
    private static let cache = LoginPathCache()

    private final class LoginPathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String]?
        /// #1162: the shell runs outside the lock, so a slow login shell holds up only the callers that
        /// need its answer, never one that already has it. Two first callers may both capture; the first
        /// answer published is the one everyone keeps.
        func get() -> [String] {
            if let cached = lock.withLock({ value }) { return cached }
            let captured = BinaryResolver.captureLoginPath()
            return lock.withLock {
                if let value { return value }
                value = captured
                return captured
            }
        }
    }

    private static var loginShellPath: [String] { cache.get() }

    /// Resolves the login-shell PATH on a background queue, so the first reader on the main thread
    /// (a sidebar row's context menu, #1001) finds it cached instead of waiting on a subprocess.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = cache.get() }
    }

    /// Runs the login shell to write its `PATH` to a file and returns the entries; empty on any failure,
    /// after `timeout`, or when the file is not one line of absolute paths. Waits on the process's
    /// termination handler, never `waitUntilExit()`, so a caller on the main thread does not pump the run
    /// loop while it waits (#1001).
    ///
    /// #1162: no pipe. The shell's stdin, stdout and stderr are `/dev/null`, so whatever its login files
    /// start inherits nothing to hold open: a pipe read used to block for good on such a process (a
    /// daemon started "if not running"), under the cache's lock, and hung every later caller. The file is
    /// read only after the shell exits, so a partial write is never seen; a timeout terminates the shell
    /// itself and returns empty, and nothing else of the person's is touched.
    static func captureLoginPath(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                                 timeout: TimeInterval = 5) -> [String] {
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("iris-loginpath-XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { return [] }
        let dir = String(cString: made)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = (dir as NSString).appendingPathComponent("path")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", #"printf "%s" "$PATH" > "$IRIS_PATH_OUT""#]
        var environment = ProcessInfo.processInfo.environment
        environment["IRIS_PATH_OUT"] = out
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return []
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            return []
        }
        guard let text = try? String(contentsOfFile: out, encoding: .utf8) else { return [] }
        return pathEntries(text)
    }

    /// The absolute entries of a `PATH` value, or empty unless it is a single line. A relative entry (`.`,
    /// a literal `~/bin`) is dropped rather than costing the whole PATH (dev-1's review: such lines are
    /// common in login files); two lines, or none, give nothing.
    static func pathEntries(_ text: String) -> [String] {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.contains(where: \.isNewline) else { return [] }
        return line.components(separatedBy: ":").filter { $0.hasPrefix("/") }
    }

    static func defaultSearchDirs() -> [String] {
        let common = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).expandingTildeInPath }
        var seen: Set<String> = []
        return (loginShellPath + common).filter { seen.insert($0).inserted }
    }

    /// Merges the login-shell PATH (`defaultSearchDirs()`) ahead of `base`'s own PATH, so every
    /// host command spawner sees pyenv/nvm/Homebrew shims that only `.zprofile`/`.zshrc` set up
    /// (#69) without spawning a login shell per command (which prints profile banners and can have
    /// side effects). Order is preserved and duplicates are removed, keeping the first occurrence.
    /// Other keys pass through unchanged.
    static func commandEnvironment(base: [String: String]) -> [String: String] {
        let loginPath = defaultSearchDirs()
        guard !loginPath.isEmpty else { return base }
        let basePath = base["PATH"]?.components(separatedBy: ":").filter { !$0.isEmpty } ?? []
        var seen: Set<String> = []
        let merged = (loginPath + basePath).filter { seen.insert($0).inserted }
        var env = base
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    /// Resolution order: absolute/relative path as given > search dirs.
    ///
    /// `relativeTo` is the directory a relative command resolves against. It defaults to the
    /// process working directory, which is what a shell would do — but taking it as a parameter
    /// means a test can exercise relative resolution without calling
    /// `changeCurrentDirectoryPath`, which is process-global and raced every other suite running
    /// in parallel (#242).
    static func resolve(command: String, searchDirs: [String]? = nil,
                        relativeTo base: String = FileManager.default.currentDirectoryPath) -> String? {
        let fm = FileManager.default
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            // An absolute `expanded` ignores the base, which is the behaviour we want.
            let path = URL(fileURLWithPath: expanded,
                           relativeTo: URL(fileURLWithPath: base, isDirectory: true))
                .standardizedFileURL.path
            guard fm.isExecutableFile(atPath: path) else { return nil }
            return path
        }
        for dir in searchDirs ?? defaultSearchDirs() {
            let candidate = "\(dir)/\(expanded)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
