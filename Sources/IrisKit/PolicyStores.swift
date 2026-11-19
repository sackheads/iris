import Foundation

/// #974 Task 9b (F6 / Invariant 6): the access-policy stores, `profiles/` (the `AccessProfileStore`:
/// each named `AccessProfile` and the identity-to-profile mappings) and `config/a2a-peers/` (the
/// peer keys). Both are already inside `IrisPaths.protectedWriteDirs`, so a `write_file` there is a
/// protected write; what this adds is the text side: naming them for the approval dialog, and
/// recognizing a host command that writes one, which `isProtectedWrite` (path-based, file tools
/// only) cannot see. Best effort on the text, like `WorkspaceIrisDir.commandNamesWorkspaceIris`.
enum PolicyStores {
    /// The two stores' directory names, for the tests that pin them to `IrisPaths`.
    static let directoryNames = ["profiles", "a2a-peers"]

    /// What the shell would see: quotes and backslashes removed, case folded (APFS is
    /// case-insensitive).
    private static func plain(_ text: String) -> String {
        text.filter { $0 != "'" && $0 != "\"" && $0 != "\\" }.lowercased()
    }

    private static func isNameCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." }

    /// Whether `word` appears in `text` as a whole path component: not inside `user_profiles`,
    /// `profiles-old` or `profiles.json`.
    private static func hasWord(_ word: String, in text: String) -> Bool {
        var rest = Substring(text)
        var previous: Character?
        while let range = rest.range(of: word) {
            let before = rest[..<range.lowerBound].last ?? previous
            let after = rest[range.upperBound...].first
            if !(before.map(isNameCharacter) ?? false), !(after.map(isNameCharacter) ?? false) { return true }
            previous = rest[range.lowerBound...].first
            rest = rest[range.upperBound...]
        }
        return false
    }

    /// The store a text names, for the dialog's warning: `a2a-peers`, or `profiles` spelled under
    /// Iris's home (`~/.iris[-dev]/profiles`, `$HOME/.iris/profiles`, a `cd` into the home followed by
    /// a relative `profiles/`). nil for the same words elsewhere (`~/profiles`, `user_profiles`).
    static func named(in text: String) -> String? {
        let plain = plain(text)
        if plain.contains("a2a-peers") { return "config/a2a-peers/" }
        if plain.contains(".iris"), hasWord("profiles", in: plain) { return "profiles/" }
        return nil
    }

    /// Whether a host command names a store by any spelling: the text forms above, the absolute path
    /// of either home's store (and its real path), or a command run from inside a store directory.
    static func commandNamesStore(_ command: String, paths: IrisPaths, release: IrisPaths, workspace: String?) -> Bool {
        if named(in: command) != nil { return true }
        let plainCommand = plain(command)
        let dirs = [paths, release].flatMap { [$0.profilesDir, $0.a2aPeersDir] }
        for dir in dirs {
            for spelled in Set([dir.path, IrisPaths.realPath(dir.path)]) {
                let lowered = spelled.lowercased()
                var rest = Substring(plainCommand)
                while let range = rest.range(of: lowered) {
                    if !(rest[range.upperBound...].first.map(isNameCharacter) ?? false) { return true }
                    rest = rest[range.upperBound...]
                }
            }
        }
        if let workspace {
            let here = plain(IrisPaths.realPath(workspace))
            for dir in dirs {
                for spelled in Set([dir.path, IrisPaths.realPath(dir.path)]) {
                    let lowered = spelled.lowercased()
                    if here == lowered || here.hasPrefix(lowered + "/") { return true }
                }
            }
            // A command run from the Iris home or anywhere under it (its `config/` too) can name a
            // store by a bare component, `profiles/y` or `../profiles/y`, with no `.iris` in its text
            // and the workspace a PARENT of the store, not inside it (dev-2's review of #1221).
            for root in [paths, release] {
                for spelled in Set([root.root.path, IrisPaths.realPath(root.root.path)]) {
                    let lowered = spelled.lowercased()
                    guard here == lowered || here.hasPrefix(lowered + "/") else { continue }
                    if directoryNames.contains(where: { hasWord($0, in: plainCommand) }) { return true }
                }
            }
        }
        return false
    }
}
