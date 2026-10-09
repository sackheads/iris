import KeyboardShortcuts

enum Constants {
    static let appVersion = "0.1.0"
    static let gitHubRepo = "bnaylor/iris"
}

extension KeyboardShortcuts.Name {
    static let toggleIris = Self(BuildIdentity.current.hotkeyName, default: BuildIdentity.current.defaultHotkey)
}
