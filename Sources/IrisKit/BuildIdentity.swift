import Foundation
import KeyboardShortcuts

/// Which Iris this process is. Only the installed app (`com.bnaylor.iris`) is release; the bare
/// SwiftPM binary (no bundle id), the Xcode Debug app (`com.bnaylor.iris.dev`) and test runners are
/// dev, so a dev build can never open the release app's data, Keychain items or hotkey.
enum BuildIdentity: Equatable, Sendable {
    case release, dev

    static let releaseBundleIdentifier = "com.bnaylor.iris"

    static func resolve(bundleIdentifier: String?) -> BuildIdentity {
        bundleIdentifier == releaseBundleIdentifier ? .release : .dev
    }

    static let current = resolve(bundleIdentifier: Bundle.main.bundleIdentifier)

    var homeDirectoryName: String { self == .release ? ".iris" : ".iris-dev" }

    /// Appended to every Keychain service name, so dev and release never share an item.
    var keychainServiceSuffix: String { self == .release ? "" : ".dev" }

    /// A separate name, not just a separate default: a shortcut the user recorded under the old
    /// shared name stays with release instead of firing both apps.
    var hotkeyName: String { self == .release ? "toggleIris" : "toggleIrisDev" }

    var defaultHotkey: KeyboardShortcuts.Shortcut {
        self == .release
            ? .init(.space, modifiers: [.command, .shift])
            : .init(.space, modifiers: [.command, .shift, .option])
    }
}
