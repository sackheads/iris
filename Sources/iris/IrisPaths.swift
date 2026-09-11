import Foundation

/// Single source of truth for every path under the home config directory (`~/.iris`).
///
/// Storage is segregated by owner: `memory/` (bot-authored, mutable, guard-sanitized),
/// `config/` (human/app config), and `models/` (downloaded bundles). Every consumer resolves
/// paths through here instead of re-deriving `("~/.iris" as NSString).expandingTildeInPath`,
/// which removes the duplication that produced the SOUL split-brain bug. `root` is injectable
/// so `IrisMigrator` and the memory managers can be unit-tested against a temp directory.
struct IrisPaths: Sendable {
    let root: URL

    init(root: URL) { self.root = root }

    static let `default` = IrisPaths(
        root: URL(fileURLWithPath: ("~/.iris" as NSString).expandingTildeInPath)
    )

    // memory/
    var memoryDir: URL { root.appendingPathComponent("memory") }
    var soulMd: URL { memoryDir.appendingPathComponent("SOUL.md") }
    var userMd: URL { memoryDir.appendingPathComponent("USER.md") }
    var memoryMd: URL { memoryDir.appendingPathComponent("memory.md") }
    var skillsDir: URL { memoryDir.appendingPathComponent("skills") }
    var artifactsDir: URL { memoryDir.appendingPathComponent("artifacts") }
    var libraryDir: URL { memoryDir.appendingPathComponent("library") }
    var factStoreDB: URL { memoryDir.appendingPathComponent("fact_store.sqlite") }
    var holographicDB: URL { memoryDir.appendingPathComponent("holographic_memory.sqlite") }

    // config/
    var configDir: URL { root.appendingPathComponent("config") }
    var settingsJSON: URL { configDir.appendingPathComponent("settings.json") }
    var permissionsJSON: URL { configDir.appendingPathComponent("permissions.json") }
    var mcpServersJSON: URL { configDir.appendingPathComponent("mcp_servers.json") }

    // rules/
    var rulesDir: URL { root.appendingPathComponent("rules") }

    // plugins/
    var pluginsDir: URL { root.appendingPathComponent("plugins") }
    var pluginsJSON: URL { configDir.appendingPathComponent("plugins.json") }

    // models/ (resolved path unchanged from the old layout)
    var modelsDir: URL { root.appendingPathComponent("models") }

    /// True if `rawPath` resolves to a location inside `memoryDir` — used to treat reads of
    /// first-party memory content (SOUL, USER, skills, artifacts, library, ...) as trusted.
    /// Tilde-expands and standardizes the path (resolving `..`) first, so a traversal like
    /// `memory/../models/x` does NOT count as inside memory. A trailing separator on the
    /// prefix check prevents a sibling like `memory-evil` from matching.
    func isUnderMemory(_ rawPath: String) -> Bool {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let mem = memoryDir.standardizedFileURL.path
        return resolved == mem || resolved.hasPrefix(mem + "/")
    }

    /// True if `rawPath` resolves to a location inside `root` (`~/.iris`).
    /// Tilde-expands and standardizes the path (resolving `..`) first.
    func isUnderIrisDir(_ rawPath: String) -> Bool {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return resolved == rootPath || resolved.hasPrefix(rootPath + "/")
    }

    /// Create the bucket directories if absent. Called by the migrator and by managers that
    /// need their directory to exist before writing.
    func ensureDirectories() throws {
        for dir in [memoryDir, skillsDir, artifactsDir, libraryDir, configDir, modelsDir, rulesDir, pluginsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
