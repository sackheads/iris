import Foundation

/// Machine-local, per-plugin state. Lives in `~/.iris/config/plugins.json` so a plugin
/// directory stays a pure, shareable artifact with nothing machine-local inside.
struct PluginState: Codable, Sendable, Equatable {
    var enabled: Bool = true
    var source: String = "local"           // "local" | "snippet" | "import:<harness>" | "dev"
    var installedVersion: String?
    var configValues: [String: String] = [:]

    init(enabled: Bool = true, source: String = "local") {
        self.enabled = enabled
        self.source = source
    }
}

struct PluginStateStore: Sendable {
    let paths: IrisPaths

    func load() -> [String: PluginState] {
        guard let data = try? Data(contentsOf: paths.pluginsJSON),
              let states = try? JSONDecoder().decode([String: PluginState].self, from: data) else {
            return [:]
        }
        return states
    }

    func save(_ states: [String: PluginState]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(states) else { return }
        try? data.write(to: paths.pluginsJSON, options: .atomic)
    }
}
