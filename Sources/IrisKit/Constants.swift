import Foundation
import KeyboardShortcuts

enum Constants {
    /// From the bundle the release script stamps; a SwiftPM or Debug build reports "dev".
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let gitHubRepo = "sackheads/iris"
}

extension KeyboardShortcuts.Name {
    static let toggleIris = Self(BuildIdentity.current.hotkeyName, default: BuildIdentity.current.defaultHotkey)
}
