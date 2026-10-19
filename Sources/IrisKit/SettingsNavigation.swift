import Observation

/// The Settings window's tabs, as `SettingsView` tags them.
enum SettingsTab: Hashable, CaseIterable {
    case general, models, vibecop, security, integrations, advanced, plugins, updates

    var title: String {
        switch self {
        case .general:      "General"
        case .models:       "Models"
        case .vibecop:      "Vibecop"
        case .security:     "Security"
        case .integrations: "Integrations"
        case .advanced:     "Advanced"
        case .plugins:      "Plugins"
        case .updates:      "Updates"
        }
    }
}

/// Which Settings tab is showing. Transient on purpose: it is never persisted and lives on no
/// `Codable` type, so Settings opens on General after a relaunch as it always has (#88).
///
/// Settings is its own window scene, so a status light cannot hand it a parameter. It sets the
/// tab here instead, and an already-open Settings window switches because its `TabView` is
/// bound to `selected`.
@MainActor @Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var selected: SettingsTab = .general

    /// Selects `tab`, then runs `open` (the scene's `openSettings`) to show or raise the window.
    func show(_ tab: SettingsTab, open: () -> Void) {
        selected = tab
        open()
    }
}
