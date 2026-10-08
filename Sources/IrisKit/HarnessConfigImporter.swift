import Foundation

/// Read-only import of MCP server definitions from other harnesses' config files. Every
/// major harness stores the same `mcpServers` JSON shape; only the file location differs.
/// Iris never edits these files.
struct HarnessConfigImporter {
    struct DetectedHarness: Sendable, Equatable, Hashable {
        let name: String
        let configPath: URL
    }

    static let knownLocations: [(name: String, relativePath: String)] = [
        ("Claude Desktop", "Library/Application Support/Claude/claude_desktop_config.json"),
        ("Claude Code", ".claude.json"),
        ("Cursor", ".cursor/mcp.json"),
        ("Windsurf", ".codeium/windsurf/mcp_config.json"),
        ("Gemini CLI", ".gemini/settings.json"),
        ("VS Code Copilot", "Library/Application Support/Code/User/mcp.json"),
    ]

    static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DetectedHarness] {
        knownLocations.compactMap { name, relative in
            let url = home.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return DetectedHarness(name: name, configPath: url)
        }
    }

    /// Extracts the `mcpServers` object (top-level or nested among other settings) and
    /// returns each server's raw dict. Servers without a string `command` are skipped
    /// (remote/HTTP servers are out of scope in v1).
    ///
    /// Files without an `mcpServers` wrapper — like Iris's own `mcp_servers.json`, which is a
    /// bare `{ "name": { "command": ... } }` map — are treated as the server map itself; the
    /// command-is-String filter below naturally skips any non-server keys in such files.
    static func servers(at url: URL) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IPFError.invalidJSON("\(url.lastPathComponent) is not a JSON object")
        }
        let dict = (root["mcpServers"] as? [String: Any]) ?? root
        var result: [String: [String: Any]] = [:]
        for (name, any) in dict {
            guard let server = any as? [String: Any], server["command"] is String else { continue }
            result[name] = server
        }
        return result
    }

    /// Re-wraps one parsed server as a standard snippet so it flows through
    /// `PluginInstaller.draft(fromSnippet:)` — one pipeline for all import sources.
    static func snippetJSON(serverName: String, raw: [String: Any]) -> String {
        let wrapper: [String: Any] = ["mcpServers": [serverName: raw]]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
