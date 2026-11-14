import Foundation

/// What an "Always Allow" on a `run_command` saves, and what such a rule matches (#1102).
///
/// A rule used to be the whole command, byte for byte, so it never matched again: `cd /tmp &&`,
/// a `| tail -40`, a different `--filter` or a token in a header made each one unique. A *prefix*
/// rule names what the command actually does, its program and (for the tools that have them) its
/// subcommand, `git status` or `swift test`, and matches any later command whose parts each start
/// with a saved prefix.
///
/// Conservative like `ReadOnlyCommand`, for the same reason: a wrong "no match" costs a prompt; a
/// wrong match runs something nobody approved. The tokenizer refuses every shell feature it does
/// not model (substitution, redirection to a file, subshells, globs, variables, background `&`),
/// so the words after a prefix can only ever be plain arguments to that one program. A prefix is
/// never made for a program where "any arguments" means "any code" (`neverGeneralized`), for a
/// subcommand off its tool's list, or for a program spelled as a relative path (a `cd` earlier in
/// the command would move it). Prefix rules apply to attended calls only: an unattended run keeps
/// its grant and exact rules (`PermissionManager.match`).
enum CommandPattern {
    /// One simple command of a chain or pipeline. `afterPipe` when its input is the previous
    /// command's output.
    struct Segment: Equatable {
        var words: [String]
        var afterPipe: Bool
    }

    // MARK: Tokenizer

    /// Splits `command` on `&&`, `||`, `;` and `|` into simple commands of plain words, or nil for
    /// anything outside that subset. Words are `ReadOnlyCommand.words`'s: plain characters, and
    /// single or double quotes (no `$`, backtick, backslash or `!` inside double quotes). The only
    /// redirections understood are the harmless ones (`2>&1`, `>/dev/null`, `2>/dev/null`,
    /// `&>/dev/null`), which are dropped; any other `<`, `>` or lone `&` refuses.
    static func segments(_ command: String) -> [Segment]? {
        let chars = Array(command.unicodeScalars)
        var segments: [Segment] = []
        var words: [String] = []
        var current = ""
        var inWord = false
        var afterPipe = false

        func endWord() {
            if inWord { words.append(current); current = ""; inWord = false }
        }
        func endSegment(nextAfterPipe: Bool) -> Bool {
            endWord()
            guard !words.isEmpty else { return false }
            segments.append(Segment(words: words, afterPipe: afterPipe))
            words = []
            afterPipe = nextAfterPipe
            return true
        }

        var i = 0
        while i < chars.count {
            if !inWord, let skip = harmlessRedirectLength(chars, at: i) {
                i += skip
                continue
            }
            let c = chars[i]
            switch c {
            case " ", "\t":
                endWord()
            case "&":
                guard i + 1 < chars.count, chars[i + 1] == "&", endSegment(nextAfterPipe: false) else { return nil }
                i += 1
            case "|":
                if i + 1 < chars.count, chars[i + 1] == "|" {
                    guard endSegment(nextAfterPipe: false) else { return nil }
                    i += 1
                } else {
                    guard endSegment(nextAfterPipe: true) else { return nil }
                }
            case ";":
                guard endSegment(nextAfterPipe: false) else { return nil }
            case "'", "\"":
                guard let close = chars[(i + 1)...].firstIndex(of: c) else { return nil }
                let body = chars[(i + 1)..<close]
                let allowed = c == "'" ? body.allSatisfy(isPrintable)
                                       : body.allSatisfy { isPrintable($0) && !"$`\\!".unicodeScalars.contains($0) }
                guard allowed else { return nil }
                current.unicodeScalars.append(contentsOf: body)
                inWord = true
                i = close
            case "=", "%":
                // zsh expands a word starting `=cmd`, and `%` starts a job spec: only after a real
                // character (`ReadOnlyCommand.words`).
                guard !current.isEmpty else { return nil }
                current.unicodeScalars.append(c)
            default:
                guard isPlain(c) else { return nil }
                current.unicodeScalars.append(c)
                inWord = true
            }
            i += 1
        }
        guard endSegment(nextAfterPipe: false) else { return nil }
        return segments
    }

    /// The length of a harmless redirection starting at `i` (at a word's start), or nil.
    private static func harmlessRedirectLength(_ chars: [Unicode.Scalar], at i: Int) -> Int? {
        func boundary(_ j: Int) -> Bool {
            j >= chars.count || [" ", "\t", ";", "|", "&"].contains(chars[j])
        }
        func matches(_ text: String, at j: Int) -> Bool {
            let scalars = Array(text.unicodeScalars)
            guard j + scalars.count <= chars.count else { return false }
            return Array(chars[j..<(j + scalars.count)]) == scalars
        }
        if matches("2>&1", at: i), boundary(i + 4) { return 4 }
        for op in ["&>", "2>", "1>", ">"] where matches(op, at: i) {
            var j = i + op.unicodeScalars.count
            while j < chars.count, chars[j] == " " { j += 1 }
            if matches("/dev/null", at: j), boundary(j + 9) { return j + 9 - i }
            return nil
        }
        return nil
    }

    private static func isPrintable(_ c: Unicode.Scalar) -> Bool { (0x20...0x7E).contains(c.value) }

    private static func isPlain(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "a"..."z", "A"..."Z", "0"..."9", "_", ".", "/", ",", ":", "@", "+", "-", "~": return true
        default: return false
        }
    }

    // MARK: Parts that need no rule

    /// A part that only rides along in a chain: `cd` to a plain path, `pwd`, `true`, `echo`, or a
    /// filter on the right of a pipe that reads nothing but its input. On its own it is never
    /// enough: a command matches only when at least one part matched a rule (`matchedPrefixes`).
    static func isRideAlong(_ segment: Segment) -> Bool {
        let words = segment.words
        switch words[0] {
        case "cd": return words.count == 1 || (words.count == 2 && !words[1].hasPrefix("-"))
        case "pwd", "true": return words.count == 1
        case "echo": return true
        default: return segment.afterPipe && isPipeFilter(words)
        }
    }

    private typealias Flags = ReadOnlyCommand.Flags

    /// Filters and how many operands each may take: none (anything more would be a file to read),
    /// or a grep's pattern. `-f` (a pattern file) is left off every grep.
    private static let filters: [String: (flags: Flags, operands: Int)] = {
        let grep = Flags(short: Set("ivnlLcwxEFhHoqs"), shortValued: Set("emABC"),
                         long: ["ignore-case", "invert-match", "line-number", "count", "word-regexp", "fixed-strings"],
                         longValued: ["color", "colour"])
        return [
            "head": (Flags(shortValued: Set("nc")), 0),
            "tail": (Flags(short: Set("q"), shortValued: Set("nc")), 0),
            "wc": (Flags(short: Set("lwcm")), 0),
            "sort": (Flags(short: Set("rnufbhV"), shortValued: Set("kt")), 0),
            "uniq": (Flags(short: Set("cdiu")), 0),
            "cut": (Flags(shortValued: Set("dfc")), 0),
            "grep": (grep, 1), "egrep": (grep, 1), "fgrep": (grep, 1),
            "rg": (Flags(short: Set("inlcwvFSsHNo"), shortValued: Set("eABCm")), 1),
        ]
    }()

    private static func isPipeFilter(_ words: [String]) -> Bool {
        guard let (flags, maxOperands) = filters[words[0]] else { return false }
        var operands = 0
        var patternFlag = false
        var i = 1
        while i < words.count {
            let arg = words[i]
            i += 1
            // `head -15`, `tail -40`: the old count form.
            if words[0] == "head" || words[0] == "tail", arg.count > 1, arg.hasPrefix("-"), arg.dropFirst().allSatisfy(\.isNumber) { continue }
            guard arg.hasPrefix("-"), arg != "-", arg != "--" else { operands += 1; continue }
            if arg.hasPrefix("--") {
                let body = arg.dropFirst(2)
                let name = String(body.prefix { $0 != "=" })
                if body.contains("=") {
                    guard flags.longValued.contains(name) else { return false }
                } else if flags.longValued.contains(name) {
                    guard i < words.count else { return false }
                    i += 1
                } else if !flags.long.contains(name) {
                    return false
                }
                continue
            }
            var cluster = Substring(arg.dropFirst())
            while let c = cluster.first {
                cluster = cluster.dropFirst()
                if flags.short.contains(c) { continue }
                guard flags.shortValued.contains(c) else { return false }
                if c == "e" { patternFlag = true }
                if cluster.isEmpty {
                    guard i < words.count else { return false }
                    i += 1
                }
                break
            }
        }
        return operands <= (patternFlag ? 0 : maxOperands)
    }

    // MARK: Prefixes

    /// Programs no prefix is ever made for: with any arguments they run any code, reach anywhere
    /// on the network, or destroy or rewrite files or settings. An Always Allow on one of these
    /// saves the exact command, as before.
    static let neverGeneralized: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
        "python", "python2", "python3", "node", "deno", "bun", "ruby", "perl", "php", "lua", "osascript",
        "awk", "gawk", "sed", "sqlite3", "jq", "make", "npx", "uvx", "pipx", "xcrun",
        "env", "xargs", "sudo", "doas", "su", "nohup", "exec", "eval", "command", "builtin", "time", "nice",
        "timeout", "watch", "find", "parallel",
        "curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "ncat", "telnet", "ftp",
        "rm", "rmdir", "mv", "cp", "ln", "chmod", "chown", "chgrp", "dd", "tee", "truncate", "shred",
        "open", "launchctl", "security", "kill", "killall", "pkill", "crontab", "at",
        "diskutil", "tccutil", "networksetup", "pmset", "shutdown", "reboot", "csrutil", "spctl", "dscl",
    ]

    /// Programs whose arguments carry no verb worth keeping: the program alone is the rule.
    private static let wholePrograms: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "ps", "du", "df", "stat", "file",
        "which", "whoami", "uname", "date", "tree", "diff", "cmp", "sort", "uniq", "cut", "printenv",
        "hostname", "id", "groups", "uptime", "sw_vers", "lsof", "pgrep", "otool", "nm", "plutil",
        "mdls", "mkdir", "touch", "xcodebuild", "swiftlint", "swiftformat", "shellcheck", "pytest",
        "tsc", "eslint", "prettier", "ruff", "black",
    ]

    /// Tools with subcommands: the subcommands a prefix may be made for, and how many words the
    /// prefix keeps (2: `swift test`; 3: `npm run build`, `gh pr view`). Any other subcommand saves
    /// the exact command.
    private static let subcommands: [String: [String: Int]] = [
        "git": Dictionary(uniqueKeysWithValues: [
            "status", "diff", "log", "show", "branch", "add", "commit", "checkout", "switch", "restore",
            "stash", "fetch", "pull", "rev-parse", "ls-files", "blame", "grep", "remote", "tag", "worktree",
            "merge-base", "describe", "shortlog", "reflog",
        ].map { ($0, 2) }),
        "swift": ["build": 2, "test": 2],
        "npm": ["test": 2, "run": 3, "ls": 2, "outdated": 2],
        "pnpm": ["test": 2, "run": 3, "ls": 2, "outdated": 2],
        "yarn": ["test": 2, "run": 3],
        "cargo": ["build": 2, "test": 2, "check": 2, "clippy": 2, "fmt": 2, "doc": 2, "tree": 2],
        "go": ["build": 2, "test": 2, "vet": 2, "list": 2],
        "gh": ["pr": 3, "issue": 3, "run": 3, "workflow": 3, "release": 3],
        "docker": ["ps": 2, "images": 2, "logs": 2, "inspect": 2, "version": 2, "info": 2],
        "container": ["list": 2, "ls": 2, "images": 2, "logs": 2, "inspect": 2],
        "kubectl": ["get": 2, "describe": 2, "logs": 2, "top": 2, "version": 2, "explain": 2],
        "brew": ["list": 2, "info": 2, "search": 2, "outdated": 2, "doctor": 2, "deps": 2],
        "pip": ["list": 2, "show": 2, "freeze": 2],
        "pip3": ["list": 2, "show": 2, "freeze": 2],
        "defaults": ["read": 2],
        "systemctl": ["status": 2, "is-active": 2, "list-units": 2],
    ]

    /// git arguments a prefix never covers, wherever they stand: each runs a program or writes a
    /// file of the caller's choosing.
    private static let gitDeniedArgs = ["--upload-pack", "--receive-pack", "--exec", "--open-files-in-pager",
                                        "--output", "--ext-diff", "--textconv", "-O"]

    /// A word a saved prefix may hold: plain, no `=`, no quotes or spaces.
    private static func isRuleWord(_ word: String) -> Bool {
        !word.isEmpty && word.unicodeScalars.allSatisfy { c in
            switch c {
            case "a"..."z", "A"..."Z", "0"..."9", "_", ".", "/", ":", "@", "+", "-": return true
            default: return false
            }
        }
    }

    /// The words a prefix is judged against: git's two harmless global options (`-C <dir>`,
    /// `--no-pager`) dropped, or nil when the part can't be matched by a prefix at all (a relative
    /// program, which a `cd` moves; a variable assignment; git with any other global option or a
    /// denied argument).
    static func canonicalWords(_ segment: Segment) -> [String]? {
        let words = segment.words
        let program = words[0]
        guard isRuleWord(program), !program.hasPrefix("-") else { return nil }
        if program.contains("/"), !program.hasPrefix("/") { return nil }
        guard program == "git" else { return words }
        var out = ["git"]
        var i = 1
        while i < words.count, words[i].hasPrefix("-") {
            switch words[i] {
            case "-C":
                guard i + 1 < words.count else { return nil }
                i += 2
            case "--no-pager":
                i += 1
            default:
                return nil
            }
        }
        out.append(contentsOf: words[i...])
        if out.dropFirst().contains(where: { arg in gitDeniedArgs.contains { arg == $0 || arg.hasPrefix($0 + "=") } }) {
            return nil
        }
        return out
    }

    /// The prefix an Always Allow saves for one part, or nil when this part gets none.
    static func prefix(for segment: Segment) -> [String]? {
        guard let words = canonicalWords(segment) else { return nil }
        let program = words[0]
        guard !neverGeneralized.contains((program as NSString).lastPathComponent) else { return nil }
        if let subs = subcommands[program] {
            guard words.count >= 2, let depth = subs[words[1]], words.count >= depth else { return nil }
            let prefix = Array(words.prefix(depth))
            return prefix.allSatisfy({ isRuleWord($0) && !$0.hasPrefix("-") }) ? prefix : nil
        }
        if wholePrograms.contains(program) { return [program] }
        // Anything else: the program and its verb (`diskutil list`), never the program alone,
        // since an unknown tool's other verbs may do anything. No verb, no prefix.
        guard words.count >= 2, !words[1].hasPrefix("-"), isRuleWord(words[1]),
              words[1].unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "-" }) else { return nil }
        return [program, words[1]]
    }

    /// The prefixes an Always Allow on `command` saves, one per part that is not a ride-along, or
    /// nil when any such part gets none (then the exact command is saved, as before) or there is
    /// no such part.
    static func alwaysAllowPrefixes(_ command: String) -> [[String]]? {
        guard let segments = segments(command) else { return nil }
        var out: [[String]] = []
        for segment in segments where !isRideAlong(segment) {
            guard let prefix = prefix(for: segment) else { return nil }
            if !out.contains(prefix) { out.append(prefix) }
        }
        return out.isEmpty ? nil : out
    }

    /// For each part that is not a ride-along, the index in `prefixes` of the first prefix it
    /// starts with; nil when any such part matches none, the command doesn't parse, or every part
    /// is a ride-along (`cd x && pwd` is not approved by a rule it never used).
    static func matchedPrefixes(_ command: String, prefixes: [[String]]) -> [Int]? {
        guard !prefixes.isEmpty, let segments = segments(command) else { return nil }
        var used: [Int] = []
        for segment in segments where !isRideAlong(segment) {
            guard let words = canonicalWords(segment),
                  let index = prefixes.firstIndex(where: { !$0.isEmpty && words.starts(with: $0) }) else { return nil }
            used.append(index)
        }
        return used.isEmpty ? nil : used
    }
}
