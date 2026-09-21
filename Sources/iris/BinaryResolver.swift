import Foundation

/// Resolves MCP server commands to absolute executable paths. GUI apps do not inherit the
/// user's shell PATH, so a bare command like `notebooklm-mcp` is resolved against the login
/// shell's PATH (captured once per launch) plus the common install locations. Iris never
/// installs runtimes itself.
enum BinaryResolver {
    /// Login-shell PATH entries, captured once. Falls back to empty on any failure.
    private static let loginShellPath: [String] = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
            process.waitUntilExit()
            timeout.cancel()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: ":").filter { !$0.isEmpty }
        } catch {
            return []
        }
    }()

    static func defaultSearchDirs() -> [String] {
        let common = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).expandingTildeInPath }
        var seen: Set<String> = []
        return (loginShellPath + common).filter { seen.insert($0).inserted }
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
