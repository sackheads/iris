import Foundation

/// #1316: a write that plants something a Mac program later runs, a git hook or config, a shell
/// startup file, an SSH config, a launch agent, outlives `/yolo off` the way a permission grant does,
/// so YOLO does not approve it (`AppState.requestApprovalSource`): the call takes the ordinary ladder,
/// as with YOLO off. The files are `VibecopService.hostRunFiles` (#613), plus `.config/git/config`.
/// #1327 adds the jobs a command plants without writing one of them: a crontab, a launchd job.
/// Best effort on a command's text, like `PolicyStores`: a path built at run time is not seen.
enum HostRunFiles {
    private static let startupFiles: Set<String> = [".gitconfig", ".zshenv", ".zshrc", ".zprofile", ".zlogin", ".zlogout",
                                                    ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".profile", ".envrc"]

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
        // Each list of words is scanned, and so is every quoted span re-split as a command of its own:
        // `sh -c 'echo x >> ~/.zshrc'` and `bash -lc "git config core.hooksPath h"` are the usual shapes
        // of a model-written command (dev-1's review). Bounded, since a span re-splits into shorter ones.
        for text in commandTexts(command, depth: 4) {
            let list = words(text)
            // An assignment's value is a path too (`X=~/.zshrc`, `--file=.git/config`).
            if list.flatMap({ $0.split(separator: "=").map(String.init) }).contains(where: isRunFile) { return true }
            if setsGitConfig(list) { return true }
            if segments(text).contains(where: plantsJob) { return true }
        }
        return false
    }

    /// `command`'s words, then the words of each word that is itself more than one, recursively.
    static func wordLists(_ command: String, depth: Int) -> [[String]] {
        commandTexts(command, depth: depth).map(words)
    }

    /// `command`, then each of its words that is itself more than one (a quoted `sh -c` body), recursively.
    private static func commandTexts(_ command: String, depth: Int) -> [String] {
        guard depth > 0 else { return [command] }
        return [command] + words(command).filter { word in word.contains { $0.isWhitespace || "><|;&()`$".contains($0) } }
            .flatMap { commandTexts($0, depth: depth - 1) }
    }

    /// #1327: a persistent job a later launch runs, planted without writing any listed file. `crontab` with
    /// anything but `-l` (a file, `-` for stdin, none at all, `-e`, `-r`), `launchctl load`, `bootstrap`,
    /// `enable` or `submit`, and `at`/`batch` queueing a job. Only in the command's own position, so
    /// `man crontab` and `echo meet at 5` are not one.
    static func plantsJob(_ segment: [String]) -> Bool {
        guard let i = commandIndex(segment) else { return false }
        let program = (segment[i] as NSString).lastPathComponent
        var args = Array(segment[(i + 1)...])
        switch program {
        case "crontab":
            if let u = args.firstIndex(of: "-u"), u + 1 < args.count { args.removeSubrange(u...(u + 1)) }
            return args != ["-l"]
        case "launchctl":
            // `launchctl asuser <uid> <command…>` runs its tail as that user (dev-1's review).
            if args.first == "asuser" { return plantsJob(Array(args.dropFirst(2))) }
            return args.first.map { ["load", "bootstrap", "enable", "submit"].contains($0) } ?? false
        // Planner's ruling: a queued `at` job waits for atrun (off by default on macOS) and fires once it
        // is enabled, long after anyone remembers it. Listing (`at -l`, `atq`) and removal (`at -r`/`-d`,
        // `atrm`) only narrow, so they run.
        case "at":
            return !args.contains { ["-l", "-r", "-d"].contains($0) }
        case "batch":
            return true
        default:
            return false
        }
    }

    /// Where a segment's program is: past variable assignments and the wrappers that run the next word
    /// (`sudo`, `env`, `nohup`, `command`, `exec`, `time`, `nice`, `doas`, and from dev-1's review `xargs`,
    /// `timeout`, `caffeinate`, `stdbuf`) with their own options; `timeout` also takes its duration first.
    /// Each wrapper's options that take a value as the next word (dev-2's review: one shared table read
    /// `time -p` as sudo's `-p prompt` and skipped the program).
    private static let wrapperValueOptions: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U"], "doas": ["-u", "-C"],
        "env": ["-u", "-S", "-P"], "nice": ["-n"], "exec": ["-a"], "time": [], "nohup": [], "command": [],
        "xargs": ["-n", "-I", "-L", "-P", "-s", "-E", "-d", "-J", "-R"], "timeout": ["-s", "-k"],
        "caffeinate": ["-t", "-w"], "stdbuf": ["-i", "-o", "-e"],
    ]

    private static func commandIndex(_ segment: [String]) -> Int? {
        var i = 0
        while i < segment.count {
            let word = segment[i]
            if word.contains("=") && !word.hasPrefix("-") { i += 1; continue }
            let wrapper = (word as NSString).lastPathComponent
            guard let takesValue = wrapperValueOptions[wrapper] else { return i }
            i += 1
            while i < segment.count, segment[i].hasPrefix("-") {
                // `command -v name` / `-V` looks the name up; it runs nothing.
                if wrapper == "command", ["-v", "-V"].contains(segment[i]) { return nil }
                i += takesValue.contains(segment[i]) ? 2 : 1
            }
            if wrapper == "timeout", i < segment.count { i += 1 }   // the duration
        }
        return nil
    }

    /// The command's simple commands: its words, split again at the list, pipe and grouping characters
    /// (`;`, `&`, `|`, parentheses, a backtick) and at a line break, which `words` treats as plain gaps.
    static func segments(_ command: String) -> [[String]] {
        var result: [[String]] = [[]], skipNext = false
        for token in tokens(command) {
            guard let token else {
                if !result[result.count - 1].isEmpty { result.append([]) }
                skipNext = false
                continue
            }
            if token == redirectMark { skipNext = true; continue }
            if skipNext { skipNext = false; continue }   // a redirect's target (`crontab -l > backup.txt`)
            result[result.count - 1].append(token)
        }
        return result.filter { !$0.isEmpty }
    }

    /// The command's shell words: split at unquoted whitespace and the shell's redirection, pipe and
    /// list characters, so `>.git/hooks/x` counts, with a quoted span kept whole and its quotes removed.
    /// dev-2's review: stripping quotes before splitting made `-c "user.name=Iris Bot"` two words, so
    /// the `git config` scan below lost its place.
    static func words(_ command: String) -> [String] {
        tokens(command).compactMap { $0 }.filter { $0 != redirectMark }
    }

    /// Stands for `>` or `<` in `tokens`: the word after it is where the output goes, not an argument.
    private static let redirectMark = "\u{1}redirect"

    /// `words`, with a nil where a simple command ends (see `segments`).
    private static func tokens(_ command: String) -> [String?] {
        var words: [String?] = [], current = "", quote: Character?, escaped = false, started = false
        func end() { if started { words.append(current) }; current = ""; started = false }
        for c in command {
            if escaped { current.append(c); escaped = false; started = true; continue }
            if c == "\\", quote != "'" { escaped = true; started = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
                continue
            }
            if c == "'" || c == "\"" { quote = c; started = true; continue }
            if c.isNewline || ";&|()`".contains(c) { end(); words.append(nil); continue }
            if "><".contains(c) { end(); words.append(redirectMark); continue }
            if c.isWhitespace { end(); continue }
            current.append(c); started = true
        }
        end()
        return words
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
                if words[j] == "-c" { j += 2 }   // `-c key=value`, one shell word however it is quoted
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
