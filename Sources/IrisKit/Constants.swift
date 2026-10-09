import Foundation
import KeyboardShortcuts

enum Constants {
    /// From the bundle the release script stamps; a SwiftPM build reports "dev" (no bundle, so no
    /// Info.plist to read), and an unstamped Xcode build reports "0.0.0" (`MARKETING_VERSION`'s
    /// default in `project.yml`).
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let gitHubRepo = "sackheads/iris"
}

extension KeyboardShortcuts.Name {
    static let toggleIris = Self(BuildIdentity.current.hotkeyName, default: BuildIdentity.current.defaultHotkey)
}
