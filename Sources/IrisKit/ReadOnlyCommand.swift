import Foundation

/// Whether a host `run_command` can only read (#600). On the host, a Vibecop APPROVE runs a call
/// with no prompt only when this says yes; anything else goes to the person.
///
/// Conservative by construction: an allowlist of programs with per-program argument rules, over a
/// tokenizer that refuses every shell feature it does not model. A wrong "may write" costs a
/// prompt; a wrong "read-only" is a silent host write, so anything unparsed, unknown or ambiguous
/// is "may write". It judges a string and never rewrites what runs, so a program is allowed only
/// if no file it reads can make it run another one. The sandbox VM writes the conversation's
/// workspace with no prompt, so a file there is planted as easily as a command: that rules out git
/// altogether (a repository's config runs programs on reads: `core.fsmonitor`, `diff.external`,
/// textconv and clean filters) and is why a read this approves runs restricted
/// (`restrictedPath`): the run is the one judged.
enum ReadOnlyCommand {
    static func isReadOnly(_ command: String) -> Bool {
        guard let words = words(command), let program = words.first else { return false }
        let args = Array(words.dropFirst())
        // `echo` (a zsh builtin) prints its arguments and nothing else, whatever they are.
        if program == "echo" { return true }
        if program == "find" { return findIsReadOnly(args) }
        guard let flags = programs[program] else { return false }
        return flagsAllowed(args, flags)
    }

    /// The options a program may be given: an allowlist, never a blocklist (#606 review: one
    /// unlisted flag, `rg --hostname-bin`, runs any file). Each one listed reads and nothing else,
    /// on BSD and GNU builds both, and runs no other program: not `rg -z` or `file -z`, which fork
    /// decompressors from `PATH`. Small on purpose; a flag left out costs a prompt.
    struct Flags {
        var short: Set<Character> = []
        /// Short options that take a value, attached (`-n20`) or as the next word.
        var shortValued: Set<Character> = []
        var long: Set<String> = []
        /// Long options that take a value, as `--name=value` or the next word.
        var longValued: Set<String> = []
    }

    private static let grepFlags = Flags(short: Set("ivnrRlLcwxEFhHoqs"), shortValued: Set("efmABC"),
                                         long: ["ignore-case", "invert-match", "line-number", "recursive",
                                                "files-with-matches", "count", "word-regexp", "fixed-strings"],
                                         longValued: ["include", "exclude", "exclude-dir", "max-count"])

    static let programs: [String: Flags] = [
        "ls": Flags(short: Set("1aAdFhilnoprRsStT"), long: ["all", "almost-all", "human-readable", "recursive", "reverse"]),
        "cat": Flags(short: Set("nbsvet")),
        "head": Flags(shortValued: Set("nc")),
        "tail": Flags(short: Set("q"), shortValued: Set("nc")),
        "wc": Flags(short: Set("lwcm")),
        "pwd": Flags(short: Set("LP")),
        "which": Flags(short: Set("as")),
        "stat": Flags(short: Set("Llx"), shortValued: Set("fc")),
        "du": Flags(short: Set("shackm"), shortValued: Set("d")),
        "df": Flags(short: Set("hkil")),
        "grep": grepFlags, "egrep": grepFlags, "fgrep": grepFlags,
        "basename": Flags(), "dirname": Flags(), "whoami": Flags(),
        "uname": Flags(short: Set("amnrsp")),
        "file": Flags(short: Set("biLh")),
        "rg": Flags(short: Set("inlcwvFSsHNuo"), shortValued: Set("egtTABCm"),
                    long: ["files", "hidden", "no-ignore", "fixed-strings", "ignore-case", "smart-case",
                           "line-number", "count", "files-with-matches", "word-regexp"],
                    longValued: ["glob", "type", "type-not", "max-count", "context", "max-depth"]),
    ]

    /// Checks every option against `flags`, wherever it stands (GNU tools take options after
    /// operands). Combined short options are split; a valued one takes the rest of its word or the
    /// next word. After `--`, only operands. A long option must be spelled out exactly, since
    /// getopt_long would read an abbreviation as whichever option it prefixes.
    static func flagsAllowed(_ args: [String], _ flags: Flags) -> Bool {
        var i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            if arg == "--" { return true }
            guard arg.hasPrefix("-"), arg != "-" else { continue }
            if arg.hasPrefix("--") {
                let body = arg.dropFirst(2)
                let name = String(body.prefix { $0 != "=" })
                if body.contains("=") {
                    guard flags.longValued.contains(name) else { return false }
                } else if flags.longValued.contains(name) {
                    guard i < args.count else { return false }
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
                if cluster.isEmpty {
                    guard i < args.count else { return false }
                    i += 1
                }
                break
            }
        }
        return true
    }

    /// `find`'s own grammar: leading options, then paths, then an expression of tests. Every word
    /// from the first dash on must be a listed test or the value of the one before it, so an action
    /// (`-delete`, `-exec`, `-fprint`, `-ok`) or anything unlisted refuses.
    static func findIsReadOnly(_ args: [String]) -> Bool {
        let options: Set<String> = ["-L", "-H", "-P", "-E", "-x"]
        let tests: Set<String> = ["-print", "-print0", "-empty", "-not", "-and", "-or", "-a", "-o", "-prune"]
        let valued: Set<String> = ["-name", "-iname", "-path", "-ipath", "-type", "-maxdepth", "-mindepth",
                                   "-size", "-mtime", "-mmin", "-newer", "-regex", "-iregex", "-perm", "-user", "-group"]
        var i = 0
        while i < args.count, options.contains(args[i]) { i += 1 }
        while i < args.count, !args[i].hasPrefix("-") { i += 1 }
        while i < args.count {
            let word = args[i]
            i += 1
            if tests.contains(word) { continue }
            guard valued.contains(word), i < args.count else { return false }
            i += 1
        }
        return true
    }

    /// Where a host command would run from: its `PATH`, its working directory, the home folder,
    /// every folder a sandbox mount can write (each conversation's workspace, each grant's
    /// read-write mount), and how to test for an executable. `live` is this process's; a test
    /// builds its own.
    struct HostLookup: Sendable {
        var path: String
        var cwd: String
        var home: String
        var writableRoots: [String] = []
        var isExecutable: @Sendable (String) -> Bool

        static func live(writableRoots: [String]) -> HostLookup {
            HostLookup(path: BinaryResolver.commandEnvironment(base: ProcessInfo.processInfo.environment)["PATH"] ?? "",
                       cwd: FileManager.default.currentDirectoryPath, home: NSHomeDirectory(),
                       writableRoots: writableRoots,
                       isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
        }
    }

    /// zsh runs these itself, never from `PATH`.
    private static let zshBuiltins: Set<String> = ["echo", "pwd", "which"]

    /// The `PATH` a silent host read runs with, or nil when it may not run silently (#612).
    ///
    /// The gate judges a string, so the run must be the one judged: a read this approves runs as
    /// `/bin/zsh -f -c` with exactly this `PATH` and `restrictedEnvironment`. `-f` skips the
    /// user's startup files (`~/.zshenv` could reorder `PATH` or run anything); zsh still reads
    /// `/etc/zshenv`, which is root-owned. The `PATH` keeps only absolute entries outside home,
    /// the working directory and every folder a sandbox mount can write, symlinks resolved. A
    /// Homebrew prefix qualifies only because no sandbox mounts it; a mount covering one drops it.
    /// The program must be found on that `PATH` (a zsh builtin needs none), and the working
    /// directory must not be home or above it.
    static func restrictedPath(program: String, cwd: String?, lookup: HostLookup) -> [String]? {
        let home = real(lookup.home)
        let dir = real(cwd ?? lookup.cwd)
        guard !inside(home, dir) else { return nil }
        let unsafe = [home, dir] + lookup.writableRoots.map(real)
        var path: [String] = []
        for entry in lookup.path.split(separator: ":").map(String.init)
        where entry.hasPrefix("/") && !path.contains(entry) {
            let resolved = real(entry)
            if !unsafe.contains(where: { inside(resolved, $0) }) { path.append(entry) }
        }
        if zshBuiltins.contains(program) { return path }
        return path.contains { lookup.isExecutable($0 + "/" + program) } ? path : nil
    }

    /// The whole environment of a silent host read: the judged `PATH` and the few basics a read
    /// needs, from `base`. Nothing else is inherited, so no `DYLD_*`, `ZDOTDIR`, `ENV`, `GIT_*`,
    /// `RIPGREP_CONFIG_PATH` or `GREP_OPTIONS` can change what runs.
    static func restrictedEnvironment(path: [String], base: [String: String]) -> [String: String] {
        var env = base.filter { key, _ in ["HOME", "USER", "LOGNAME", "TERM", "LANG"].contains(key) || key.hasPrefix("LC_") }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    /// What a Vibecop APPROVE may do (#600, #612).
    enum VibecopGate: Equatable {
        /// Ask the person.
        case ask
        /// Run as usual: any command in the VM, or a file read.
        case run
        /// Run restricted, with this `PATH` (see `restrictedPath`).
        case runRestricted(path: [String])
    }

    /// In the VM, any command: the in-VM rules are unchanged. On the host, a read-only command,
    /// restricted, or a file read. A file write is a write wherever it lands.
    ///
    /// `homeWritable` (#611, the owner's "1: a"): the conversation let the sandbox write a home
    /// folder or above it, so the VM is no safe box, and in it too only a read-only command runs
    /// on an APPROVE. The VM has its own `PATH`, so the host lookup does not apply there.
    static func vibecopGate(toolName: String, details: String, inSandbox: Bool, homeWritable: Bool = false,
                            cwd: String? = nil, lookup: @autoclosure () -> HostLookup) -> VibecopGate {
        switch toolName {
        case "run_command":
            if inSandbox { return !homeWritable || isReadOnly(details) ? .run : .ask }
            guard isReadOnly(details), let program = words(details)?.first,
                  let path = restrictedPath(program: program, cwd: cwd, lookup: lookup()) else { return .ask }
            return .runRestricted(path: path)
        case "read_file": return .run
        default: return .ask
        }
    }

    private static func real(_ path: String) -> String {
        URL(fileURLWithPath: IrisEngine.expandTilde(path)).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Whether `path` is `dir` or below it.
    private static func inside(_ path: String, _ dir: String) -> Bool {
        dir == "/" || path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    /// Splits a command into words the way the shell would, or nil for anything outside the subset
    /// modelled here: plain words of `[A-Za-z0-9_./,:@+~-]` (and `=` past a word's first character),
    /// single quotes, and double quotes holding no `$`, backtick, backslash or `!`. ASCII only,
    /// space-separated, one line. That leaves out every redirection, pipe, chain, substitution,
    /// subshell, glob, brace, escape, comment and variable, without listing them.
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
                // zsh expands a word that starts `=cmd` to that command's path, and quotes that
                // remove to nothing do not stop it (`''=ls`): only after a real character.
                guard !current.isEmpty else { return nil }
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
