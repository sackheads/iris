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
        func get() -> [String] {
            lock.lock(); defer { lock.unlock() }
            if let value { return value }
            let captured = BinaryResolver.captureLoginPath()
            value = captured
            return captured
        }
    }

    private static var loginShellPath: [String] { cache.get() }

    /// Resolves the login-shell PATH on a background queue, so the first reader on the main thread
    /// (a sidebar row's context menu, #1001) finds it cached instead of waiting on a subprocess.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = cache.get() }
    }

    /// Runs `shell -lc 'echo $PATH'` and returns its entries; empty on any failure or after
    /// `timeout`. Waits on the process's termination handler, never `waitUntilExit()`, so a caller
    /// on the main thread does not pump the run loop while it waits.
    static func captureLoginPath(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                                 timeout: TimeInterval = 5) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ":").filter { !$0.isEmpty }
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
