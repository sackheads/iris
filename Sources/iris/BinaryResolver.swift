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
    static func resolve(command: String, searchDirs: [String]? = nil) -> String? {
        let fm = FileManager.default
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            guard fm.isExecutableFile(atPath: expanded) else { return nil }
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        for dir in searchDirs ?? defaultSearchDirs() {
            let candidate = "\(dir)/\(expanded)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
