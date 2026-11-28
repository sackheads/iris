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
        if let workspace, components(of: resolved, under: IrisPaths.canonicalPath(workspace)) != nil { return false }
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
                guard let eq = word.firstIndex(of: "=") else { return false }
                candidate = String(word[word.index(after: eq)...])
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
                if let short, !option.hasPrefix("--"), option.dropFirst().contains(short) { return true }
                return false
            }
        }
        let recursive: Bool, follows: Bool
        switch program {
        case "rg", "ag", "ack", "fd", "fdfind", "tree", "du", "find":
            recursive = true
            follows = program == "find" ? words.contains("-L") || words.contains("-follow") || words.contains("-H")
                : program == "tree" ? has("l") : has("L", "--follow")
        case "grep", "egrep", "fgrep":
            recursive = has("r", "--recursive") || has("R", "--dereference-recursive") || options.contains { $0.hasPrefix("--directories=recurse") || $0 == "-drecurse" }
            follows = has("R", "--dereference-recursive")
        case "ls":
            recursive = has("R", "--recursive")
            follows = recursive && has("L", "--dereference")
        default:
            return false
        }
        guard recursive else { return false }
        // Roots: the words that aren't options (a pattern among them is judged too, on the asking side); `find`'s stop at
        // its first expression. None means the call's own directory.
        var roots: [String] = []
        for word in words.dropFirst() {
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
            if follows, let workspace {
                let ws = IrisPaths.canonicalPath(workspace).lowercased()
                if lowered != ws && !lowered.hasPrefix(ws + "/") { return true }
            } else if follows {
                return true
            }
            return false
        }
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
