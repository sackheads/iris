import Foundation

/// #1450 (planner's ruling): which host reads Vibecop's APPROVE may not stand in for the person on, by the shape of the
/// path rather than a list of known stores, since a list misses things. Vibecop stays free to approve reads of the
/// person's own files anywhere (a vault, `~/d.md`, `Documents`): that is a first-class workflow it exists to save
/// prompts on. It asks instead when the resolved path (`~` and `$HOME` expanded, relative to the call's directory,
/// every existing symlink followed):
/// - has a hidden component under the home folder (`~/.ssh/…`, `~/.netrc`, `~/.config/gh/…`), outside the workspace;
/// - is under `~/Library`;
/// - or is a credential by its own name anywhere, the workspace included: `.env`, `.env.*`, `*.pem`, `*.key`, `id_*`,
///   plus `DirectoryReadRule`'s secret names.
/// The workspace's own dot-paths (`.git`, `.github`) stay approvable. A path built at run time (a variable, a
/// substitution) never reaches here, since `ReadOnlyCommand.isReadOnly` refuses it; a glob is judged by its pattern,
/// best effort (#1373's class).
enum SecretReadShape {
    static func asks(path raw: String, cwd: String?, workspace: String?, home: String = NSHomeDirectory()) -> Bool {
        let resolved = resolve(raw, cwd: cwd, home: home)
        if credentialName(resolved) { return true }
        let homeReal = IrisPaths.canonicalPath(home)
        guard let below = components(of: resolved, under: homeReal) else { return false }
        if below.first?.lowercased() == "library" { return true }
        // The workspace's own dot-paths stay approvable, but only for a workspace strictly below home: one that is home,
        // or above it, would make every home dotfile its own (dev-3's #1451 review).
        if let workspace, let ws = ownWorkspace(workspace, home: home), components(of: resolved, under: ws) != nil { return false }
        return below.contains { $0.hasPrefix(".") || globMayMatchHidden($0) }
    }

    /// Every file a host command's words could name: each word that isn't an option, and an option's `=value`. A
    /// recursive read also asks when it would walk into what a single read may not (`recursiveAsks`).
    static func asks(command: String, cwd: String?, workspace: String?, home: String = NSHomeDirectory()) -> Bool {
        guard let words = ReadOnlyCommand.words(command) else { return true }
        if recursiveAsks(words, cwd: cwd, workspace: workspace, home: home) { return true }
        return words.dropFirst().contains { word in
            let candidate: String
            if word.hasPrefix("-") {
                if let eq = word.firstIndex(of: "=") {
                    candidate = String(word[word.index(after: eq)...])
                } else if !word.hasPrefix("--"), word.count > 2, let slash = word.firstIndex(where: { $0 == "/" || $0 == "~" || $0 == "." }) {
                    // A short option's attached value (`-f/path`, dev-2's #1451 review): the rest of the word from its path.
                    candidate = String(word[slash...])
                } else {
                    return false
                }
            } else {
                candidate = word
            }
            return !candidate.isEmpty && asks(path: candidate, cwd: cwd, workspace: workspace, home: home)
        }
    }

    /// The Overseer's #1450 catch: a recursive read whose root is the home folder or above it walks into `~/.ssh` and
    /// `~/Library` without naming them, and one that follows symlinks can leave any root through a link. So a recursive
    /// read asks when a root is `~`, an ancestor of it (`/`, `/Users`), or a path that asks on its own; and a
    /// symlink-following one asks for any root outside the workspace.
    static func recursiveAsks(_ words: [String], cwd: String?, workspace: String?, home: String) -> Bool {
        guard let program = words.first.map({ String($0.split(separator: "/").last ?? Substring($0)) }) else { return false }
        let options = words.dropFirst().filter { $0.hasPrefix("-") && $0 != "-" && $0 != "--" }
        func has(_ short: Character? = nil, _ long: String? = nil) -> Bool {
            options.contains { option in
                if let long, option == long || option.hasPrefix(long + "=") { return true }
                // Only a cluster of flag letters (`-rn`): an attached value (`-f/var/x`) isn't flags.
                if let short, !option.hasPrefix("--"), option.dropFirst().allSatisfy({ $0.isLetter || $0 == "." }),
                   option.dropFirst().contains(short) { return true }
                return false
            }
        }
        let recursive: Bool, follows: Bool
        // A recursive read of file contents that doesn't skip hidden files (dev-2's #1451 review): `grep -r` reads `.env`.
        var readsHiddenContent = false
        switch program {
        case "rg", "ag", "ack", "fd", "fdfind", "tree", "du", "find":
            recursive = true
            follows = program == "find" ? words.contains("-L") || words.contains("-follow") || words.contains("-H")
                : program == "tree" ? has("l") : has("L", "--follow")
        case "grep", "egrep", "fgrep":
            recursive = has("r", "--recursive") || has("R", "--dereference-recursive") || options.contains { $0.hasPrefix("--directories=recurse") || $0 == "-drecurse" }
            follows = has("R", "--dereference-recursive")
            readsHiddenContent = recursive
        case "ls":
            recursive = has("R", "--recursive")
            follows = recursive && has("L", "--dereference")
        default:
            return false
        }
        if program == "rg" { readsHiddenContent = has(".", "--hidden") || options.contains { $0.hasPrefix("-uu") } }
        if program == "ag" { readsHiddenContent = has("u", "--unrestricted") || options.contains("--hidden") }
        if program == "ack" { readsHiddenContent = true }
        guard recursive else { return false }
        // Roots: the words that aren't options (a pattern among them is judged too, on the asking side); `find`'s stop at
        // its first expression. None means the call's own directory.
        var roots: [String] = []
        for word in words.dropFirst() {
            // `find`'s own options (-H, -L, -P, -E, -X, -d, -s, -x) come before its paths; its expression starts after them.
            if program == "find", ["-H", "-L", "-P", "-E", "-X", "-d", "-s", "-x"].contains(word), roots.isEmpty { continue }
            if program == "find", word.hasPrefix("-") || word == "(" || word == "!" { break }
            if !word.hasPrefix("-") { roots.append(word) }
        }
        if roots.isEmpty || program == "rg" || program == "grep" || program == "ag" || program == "ack" {
            roots.append(cwd ?? FileManager.default.currentDirectoryPath)
        }
        let homeReal = IrisPaths.canonicalPath(home).lowercased()
        return roots.contains { root in
            let resolved = resolve(root, cwd: cwd, home: home)
            let lowered = resolved.lowercased()
            if lowered == homeReal || lowered == "/" || homeReal.hasPrefix(lowered + "/") { return true }
            if asks(path: root, cwd: cwd, workspace: workspace, home: home) { return true }
            if readsHiddenContent {
                // Outside the workspace: asks. Inside it: asks when the workspace holds a credential-shaped file.
                guard let workspace, let ws = ownWorkspace(workspace, home: home),
                      lowered == ws.lowercased() || lowered.hasPrefix(ws.lowercased() + "/") else { return true }
                if holdsCredentialFile(resolved) { return true }
            }
            // A symlink-following walk asks wherever it starts (dev-3's #1451 review, round 3): a link the repository
            // carries (`keys -> ../../.ssh`) takes it out of the workspace, and nothing short of following every link
            // can tell. Such reads are rare, so asking costs little.
            return follows
        }
    }

    /// The workspace's real path when it's strictly below home, the only kind whose own files are exempt.
    private static func ownWorkspace(_ workspace: String, home: String) -> String? {
        let ws = IrisPaths.canonicalPath(workspace)
        return components(of: ws, under: IrisPaths.canonicalPath(home))?.isEmpty == false ? ws : nil
    }

    static let credentialScanLimit = 20_000

    /// Whether `root` holds a credential-shaped file, by a bounded walk that skips `.git` and package folders. Past the
    /// limit it answers yes: a tree too big to check is judged on the asking side.
    static func holdsCredentialFile(_ root: String) -> Bool {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                                                          options: [], errorHandler: { _, _ in true }) else { return false }
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > credentialScanLimit { return true }
            let name = url.lastPathComponent
            if [".git", "node_modules", ".build", "DerivedData"].contains(name) { walker.skipDescendants(); continue }
            if credentialName(name) { return true }
        }
        return false
    }

    private static func resolve(_ raw: String, cwd: String?, home: String) -> String {
        var path = raw
        for spelling in ["$HOME", "${HOME}"] where path == spelling || path.hasPrefix(spelling + "/") {
            path = home + path.dropFirst(spelling.count)
        }
        if path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        // A glob can't be resolved as a file; its literal directory part can, and its components are judged as written.
        return IrisPaths.canonicalPath(ToolExecutor.resolvePath(path, cwd: cwd))
    }

    private static func components(of path: String, under root: String) -> [String]? {
        let p = path.lowercased(), r = root.lowercased()
        guard p.hasPrefix(r + "/") else { return nil }
        return path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    }

    /// `?` and `[` can match a leading dot in some shells' settings; `*` can't in zsh's default, but a pattern that
    /// starts with one of them is judged on the asking side anyway.
    private static func globMayMatchHidden(_ component: String) -> Bool {
        guard let first = component.first else { return false }
        return first == "?" || first == "[" || first == "*"
    }

    static func credentialName(_ path: String) -> Bool {
        guard let name = path.split(separator: "/").last.map({ String($0).lowercased() }) else { return false }
        // `.env.*` and `id_*` beyond the key names `DirectoryReadRule` lists, then its credential shapes. Not its substring
        // fragments (`token`, `history`, `private`): tuned for a folder rule's one click, they'd make Vibecop ask on
        // `history.md` or `token.swift` in every project.
        if name.hasPrefix(".env.") || name.hasPrefix("id_") { return true }
        return DirectoryReadRule.isCredentialShaped(name)
    }
}
