import Foundation

/// #1316: a write that plants something a Mac program later runs, a git hook or config, a shell
/// startup file, an SSH config, a launch agent, outlives `/yolo off` the way a permission grant does,
/// so YOLO does not approve it (`AppState.requestApprovalSource`): the call takes the ordinary ladder,
/// as with YOLO off. The files are `VibecopService.hostRunFiles` (#613), plus `.config/git/config`.
/// Best effort on a command's text, like `PolicyStores`: a path built at run time is not seen.
enum HostRunFiles {
    private static let startupFiles: Set<String> = [".gitconfig", ".zshenv", ".zshrc", ".zprofile", ".bashrc",
                                                    ".bash_profile", ".profile", ".envrc"]

    /// Whether `path` names one of the files, or a directory that holds them (`.git/hooks`, `.ssh`),
    /// by its components: `.zshrc.bak` and `.github/` are not.
    static func isRunFile(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            let rest = parts[(i + 1)...]
            // A git dir: `.git`, or a bare `name.git`, then hooks/ anywhere below (a submodule's
            // `.git/modules/x/hooks` too) or a `config` file.
            if part == ".git" || (part.hasSuffix(".git") && part.count > 4) {
                if rest.contains("hooks") || rest.contains("config") { return true }
            }
            if part == ".ssh" { return true }
            if part == "library", rest.first == "launchagents" { return true }
            if part == ".vscode", rest.first == "tasks.json" { return true }
            if part == ".config", rest.first == "git", rest.dropFirst().first == "config" { return true }
        }
        return parts.last.map(startupFiles.contains) ?? false
    }

    /// Whether a host command names one of the files in any word (after redirections and `=`), or
    /// sets a git config value. A command that can only read is never one (`ReadOnlyCommand`).
    static func commandWrites(_ command: String) -> Bool {
        guard !ReadOnlyCommand.isReadOnly(command) else { return false }
        let words = Self.words(command)
        if words.contains(where: isRunFile) { return true }
        return setsGitConfig(words)
    }

    /// The command's words, quotes and backslashes removed, split at whitespace and the shell's
    /// redirection, pipe, list and assignment characters, so `>.git/hooks/x` and `X=~/.zshrc` count.
    static func words(_ command: String) -> [String] {
        let plain = command.filter { $0 != "'" && $0 != "\"" && $0 != "\\" }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "><|;&()`="))
        return plain.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// Planner's ruling (F2 a): any `git config` that sets a value, whatever the key. Git's set of
    /// keys that run a program (`core.hooksPath`, `alias.*`, `core.fsmonitor`, filter drivers,
    /// `include.path`, ...) keeps growing, so no list of them. A read (`--get*`, `--list`, `-l`,
    /// `get`/`list`, or a key alone) is not one.
    static func setsGitConfig(_ words: [String]) -> Bool {
        var i = 0
        while i < words.count {
            guard words[i] == "git" || words[i].hasSuffix("/git") else { i += 1; continue }
            var j = i + 1
            // git's own options before the subcommand: `-C dir`, `-c k=v` (split at `=` above), `--git-dir x`.
            while j < words.count, words[j].hasPrefix("-") {
                if words[j] == "-c" { j += 3 }   // `-c key=value`, split at `=` into two words
                else if ["-C", "--git-dir", "--work-tree", "--namespace"].contains(words[j]) { j += 2 }
                else { j += 1 }
            }
            if j < words.count, words[j] == "config", configWrites(Array(words[(j + 1)...])) { return true }
            i = j + 1
        }
        return false
    }

    private static let readFlags: Set<String> = ["--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color",
                                                 "--get-colorbool", "--list", "-l", "--show-origin", "--show-scope",
                                                 "--name-only"]
    private static let writeFlags: Set<String> = ["--add", "--replace-all", "--unset", "--unset-all", "--rename-section",
                                                  "--remove-section", "-e", "--edit"]
    private static let fileFlags: Set<String> = ["--file", "-f", "--blob", "--type", "--default", "--comment"]

    private static func configWrites(_ args: [String]) -> Bool {
        if let first = args.first, ["get", "list"].contains(first) { return false }
        if let first = args.first, ["set", "unset", "rename-section", "remove-section", "edit"].contains(first) { return true }
        if args.contains(where: writeFlags.contains) { return true }
        if args.contains(where: readFlags.contains) { return false }
        var positional = 0, k = 0
        while k < args.count {
            if fileFlags.contains(args[k]) { k += 2; continue }
            if !args[k].hasPrefix("-") { positional += 1 }
            k += 1
        }
        return positional >= 2
    }
}
