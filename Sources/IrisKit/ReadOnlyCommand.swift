import Foundation

/// Whether a host `run_command` can only read (#600). On the host, a Vibecop APPROVE runs a call
/// with no prompt only when this says yes; anything else goes to the person.
///
/// Conservative by construction: an allowlist of programs with per-program argument rules, over a
/// tokenizer that refuses every shell feature it does not model. A wrong "may write" costs a
/// prompt; a wrong "read-only" is a silent host write, so anything unparsed, unknown or ambiguous
/// is "may write". What it cannot see, and does not claim to: the command's PATH lookup, the
/// shell's startup files (`zsh -c` reads `~/.zshenv`) and a repository's own git config. Planting
/// any of those needs a write that this gate never lets through silently.
enum ReadOnlyCommand {
    static func isReadOnly(_ command: String) -> Bool {
        guard let words = words(command), let program = words.first else { return false }
        let args = Array(words.dropFirst())
        switch program {
        case "ls", "cat", "head", "tail", "wc", "pwd", "which", "stat", "du", "df",
             "grep", "egrep", "fgrep", "basename", "dirname", "whoami", "uname", "echo":
            return true
        case "file":
            // `-C` / `--compile` writes a compiled magic file.
            return !args.contains { names($0, any: ["--compile"]) || (isShortFlags($0) && $0.contains("C")) }
        case "rg":
            // `--pre` runs a program on every file searched.
            return !args.contains { $0.hasPrefix("--pre") }
        case "find":
            return !args.contains { findActions.contains($0) }
        case "git":
            return gitIsReadOnly(args)
        default:
            return false
        }
    }

    /// Whether a Vibecop APPROVE may stand in for the person (#600). In the VM, any command: the
    /// in-VM rules are unchanged. On the host, only a read-only command or a file read. A file
    /// write is a write wherever it lands.
    static func vibecopMayApprove(toolName: String, details: String, inSandbox: Bool) -> Bool {
        switch toolName {
        case "run_command": return inSandbox || isReadOnly(details)
        case "read_file": return true
        default: return false
        }
    }

    private static let findActions: Set<String> = [
        "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls",
    ]

    private static let gitReads: Set<String> = [
        "status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog",
    ]

    /// `git branch` lists only with these; any other argument (a name) creates, moves or deletes.
    private static let gitBranchListFlags: Set<String> = [
        "-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "-l", "--list", "--show-current",
    ]

    private static func gitIsReadOnly(_ args: [String]) -> Bool {
        // No global options at all: `-c`, `-C`, `--exec-path`, `-p`/`--paginate`, `--git-dir` and
        // the rest come before the subcommand, so a first word that is not a known read refuses.
        guard let sub = args.first else { return false }
        let rest = args.dropFirst()
        if sub == "branch" { return rest.allSatisfy { gitBranchListFlags.contains($0) } }
        guard gitReads.contains(sub) else { return false }
        return !rest.contains { names($0, any: ["--output", "--ext-diff", "--paginate"]) }
    }

    /// Whether `arg` is one of the `forbidden` long options, spelled out or abbreviated: git's and
    /// getopt_long's parsers both accept any unambiguous prefix, so `--out=x` is `--output=x`.
    /// Also anything that starts with one (`--output-indicator-new`), which costs only a prompt.
    private static func names(_ arg: String, any forbidden: [String]) -> Bool {
        guard arg.hasPrefix("--"), arg.count > 2 else { return false }
        let name = String(arg.prefix { $0 != "=" })
        return forbidden.contains { $0.hasPrefix(name) || name.hasPrefix($0) }
    }

    private static func isShortFlags(_ arg: String) -> Bool {
        arg.hasPrefix("-") && !arg.hasPrefix("--")
    }

    /// Splits a command into words the way the shell would, or nil for anything outside the subset
    /// modelled here: plain words of `[A-Za-z0-9_./,:@+~-]` (and `=` past a word's first character),
    /// single quotes, and double quotes holding no `$`, backtick, backslash or `!`. ASCII only,
    /// space-separated, one line. That leaves out every redirection, pipe, chain, substitution, subshell, glob, brace,
    /// escape, comment and variable, without listing them.
    static func words(_ command: String) -> [String]? {
        let chars = Array(command.unicodeScalars)
        var words: [String] = []
        var current = ""
        var inWord = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ":
                if inWord { words.append(current); current = ""; inWord = false }
            case "'", "\"":
                guard let close = chars[(i + 1)...].firstIndex(of: c) else { return nil }
                let body = chars[(i + 1)..<close]
                let allowed = c == "'" ? body.allSatisfy(isPrintable)
                                       : body.allSatisfy { isPrintable($0) && !"$`\\!".unicodeScalars.contains($0) }
                guard allowed else { return nil }
                current.unicodeScalars.append(contentsOf: body)
                inWord = true
                i = close
            case "=":
                // zsh expands a leading `=cmd` to that command's path, so only inside a word.
                guard inWord else { return nil }
                current.unicodeScalars.append(c)
            default:
                guard isPlain(c) else { return nil }
                current.unicodeScalars.append(c)
                inWord = true
            }
            i += 1
        }
        if inWord { words.append(current) }
        return words
    }

    private static func isPrintable(_ c: Unicode.Scalar) -> Bool { (0x20...0x7E).contains(c.value) }

    private static func isPlain(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "a"..."z", "A"..."Z", "0"..."9", "_", ".", "/", ",", ":", "@", "+", "-", "~": return true
        default: return false
        }
    }
}
