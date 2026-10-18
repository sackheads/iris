import Testing
import Foundation
@testable import IrisKit

/// #600: on the host, a Vibecop APPROVE runs a command unprompted only when `ReadOnlyCommand` says
/// it can only read. A wrong "read-only" is a silent host write, so the refusal table is the point.
@Suite("Host read-only command gate (#600)")
struct ReadOnlyCommandTests {

    /// Every one of these must be "may write". Grouped by the trick it tries.
    static let refused: [String] = [
        // Writers, plainly.
        "rm -f x", "touch ~/rm562-probe2.txt", "rm -f ~/rm562-probe2.txt", "mkdir d", "mv a b", "cp a b",
        "chmod +x a", "ln -s a b", "dd if=a of=b", "truncate -s 0 f", "tee f", "sort -o f a", "uniq a b",
        "tree -o f", "curl -o f https://x", "wget https://x", "tar -xf a.tar", "npm install", "swift build", "make",
        // Interpreters and editors, at all.
        "sed -n p f", "sed -i s/a/b/ f", "awk 1 f", "perl -e 1", "python3 -c 1", "ruby -e 1", "osascript -e 1",
        // Side effects without a file.
        "open .", "defaults write a b c", "launchctl list", "pbcopy", "kill 1", "killall Finder",
        // Redirections and here-docs.
        "cat a > b", "echo x >> f", "cat a 2>f", "ls >f", "cat < a", "cat <<EOF", "ls 2>&1",
        // Chaining, pipes, background, newlines and continuations.
        "ls; rm -f x", "ls && rm x", "ls || rm x", "ls | sh", "ls & rm x", "ls\nrm x", "ls\rrm x", "ls \\\nrm x",
        // The same, with the operator as its own word after an allowed program, so a refusal cannot
        // come from the program check alone.
        "ls ; rm -f x", "ls ;rm -f x", "cat a && rm x", "cat a || rm x", "ls | sh", "ls |sh", "ls & rm x",
        "cat a > b", "cat a >b", "cat a >> b", "cat a 2> b", "cat a < b", "ls $(rm x)", "ls `rm x`",
        "ls ( rm x )", "ls { rm x }", "ls ! x", "ls # x", "ls * x", "ls ? x", "ls [ x", "ls ^ x", "ls % x",
        // Substitution, subshells, variables, braces, globs.
        "ls $(rm -f x)", "ls `rm -f x`", "echo $HOME", "echo ${IFS}", "ls$IFS-la", "cat <(rm x)", "(rm x)",
        "{rm,-f,x}", "ls *", "cat ?", "ls [a]", "git diff *",
        // Quoting and escaping games.
        "l\\s", "\\rm x", "\"rm\" x", "'rm' -f x", "r''m -f x", "echo \"$(rm x)\"", "echo \"`rm x`\"",
        "echo \"\\x\"", "echo \"!!\"", "cat 'unterminated", "cat \"unterminated", "ls # comment",
        // Unicode lookalikes and other whitespace.
        "\u{FF4C}\u{FF53}", "\u{217C}s", "ls\u{00A0}-la", "cat a\u{200B}", "ls\t-la", "cat 'caf\u{E9}'",
        "ls \u{FF4C}\u{FF53}", "ls a\u{00A0}b", "cat \u{0441}at",
        // Indirection: env, prefixes, wrappers, shells, paths to the binary, zsh's =cmd.
        "FOO=1 ls", "env ls", "env X=1 cat a", "xargs rm", "sudo ls", "command rm x", "builtin echo x",
        "exec ls", "eval ls", "nohup ls", "time ls", "sh -c ls", "bash -c 'ls'", "zsh -c ls", "/bin/sh -c ls",
        "/bin/ls", "./ls", "../bin/cat a", "=rm x", "ls =rm", "LS", "Cat a",
        // find's actions.
        "find . -delete", "find . -exec rm x +", "find . -execdir rm x +", "find . -ok rm x +",
        "find . -okdir rm x +", "find . -fprint f", "find . -fprintf f x", "find . -fls f",
        // git: writing subcommands, global options, writing and program-running flags, abbreviated too.
        "git", "git checkout .", "git clean -fdx", "git config user.name x", "git stash", "git commit -m x",
        "git push", "git reset --hard", "git fetch", "git gc", "git apply x", "git help log",
        "git branch new", "git branch -D x", "git branch -m a b", "git branch --list x",
        "git -c core.pager=sh log", "git -C /tmp log", "git --exec-path=/tmp log", "git -p log",
        "git --paginate log", "git --no-pager log", "git log --output=f", "git diff --output f",
        "git diff --out=f", "git diff --outp f", "git show --output-indicator-new=x", "git diff --ext-diff",
        "git diff --ext", "git log --paginate",
        // git, all of it: a repository's config runs programs on reads (fsmonitor, external diff,
        // textconv, clean filters), and the sandbox VM can write that config in its workspace.
        "git status", "git status --porcelain", "git diff", "git diff HEAD~1 -- a", "git show HEAD",
        "git log --oneline -5", "git log -p", "git blame a", "git rev-parse HEAD", "git ls-files",
        "git describe --tags", "git shortlog -sn", "git branch", "git branch -a", "git branch --show-current",
        // The overseer's list: aliases, functions, another shell by path, a bare variable.
        "alias ls=rm", "ls() { rm x; }", "/bin/zsh -c ls", "echo $IFS",
        // rg's preprocessor and file's compiler, abbreviated too.
        "rg --pre sh x", "rg --pre=sh x", "rg --pre-glob x y", "file -C -m m", "file -zC x", "file --compile",
        "file --comp",
        // work's adversarial pass on 0e69fd28 (#606): every one was read-only under the old
        // blocklists and did more than read. rg's --hostname-bin runs any file; -z and file's -z/-Z
        // fork decompressors from PATH; --show-signature runs gpg; status rewrites the index;
        // an empty quote before `=` still gets zsh's =cmd expansion.
        "rg --hostname-bin /tmp/x foo", "rg --hostname-bin=/tmp/x foo", "rg -z foo", "rg --search-zip foo",
        "rg -zl foo", "rg -lz foo", "file -z a", "file -Z a", "file -zs a", "file -bz a",
        "git log --show-signature", "git show --show-signature", "git log --format='%G?'", "git status",
        "git describe --dirty", "ls ''=ls", "ls \"\"=ls", "cat ''=cat",
        // Options that are not on a program's list, however harmless some look: the list decides.
        "grep -Z x f", "grep -z x f", "grep -J x f", "grep --decompress x f", "rg --pr=x foo", "ls -laz",
        "head -n", "rg -g", "rg --glob", "cat --show-all a", "find . -ls", "find . -name", "find '-exec' rm x +",
        // Nothing at all.
        "", "   ",
    ]

    static let allowed: [String] = [
        "ls", "ls -la", "ls -la ~/src", "ls ~", "cat README.md", "cat 'a file.txt'", "cat \"a file.txt\"",
        "head -n 20 Sources/a.swift", "tail -n 5 log.txt", "wc -l a b", "pwd", "which swift", "stat a",
        "du -sh .", "df -h", "grep -rn foo Sources", "grep -rn 'foo bar' .", "grep -E \"a|b\" f", "egrep x f",
        "basename /a/b", "dirname /a/b", "whoami", "uname -a", "echo hello", "file a", "file -b a", "rg foo",
        "rg -n 'x' Sources", "find . -name '*.swift'", "find . -type f -newer a", "cat HEAD~1",
        "ls  -la", " ls ",
    ]

    @Test("every trick in the refusal table is may-write", arguments: refused)
    func refuses(command: String) {
        #expect(!ReadOnlyCommand.isReadOnly(command), "read-only: \(command.debugDescription)")
    }

    @Test("the refusal table is the size the review asked for")
    func tableSize() {
        #expect(Self.refused.count >= 60)
    }

    @Test("plain reads pass", arguments: allowed)
    func allows(command: String) {
        #expect(ReadOnlyCommand.isReadOnly(command), "may-write: \(command.debugDescription)")
    }

    @Test("a command the tokenizer cannot parse is may-write, whatever its program")
    func unparseableIsMayWrite() {
        for command in ["ls 'unterminated", "cat \"open", "ls \\", "ls\u{0}", "ls $x", "ls\t-l", "cat \u{E9}"] {
            #expect(ReadOnlyCommand.words(command) == nil, "parsed: \(command.debugDescription)")
            #expect(!ReadOnlyCommand.isReadOnly(command))
        }
    }

    @Test("options: clusters are split, a valued one takes its value, -- ends them, long ones exact")
    func flagParsing() {
        let rg = ReadOnlyCommand.programs["rg"]!
        #expect(ReadOnlyCommand.flagsAllowed(["-uuin", "x"], rg))
        #expect(!ReadOnlyCommand.flagsAllowed(["-uiz", "x"], rg), "one unlisted letter in a cluster")
        #expect(ReadOnlyCommand.flagsAllowed(["-e", "--hostname-bin", "a"], rg), "a value is not an option")
        #expect(ReadOnlyCommand.flagsAllowed(["-ez", "a"], rg), "an attached value: the pattern z")
        #expect(ReadOnlyCommand.flagsAllowed(["--glob=*.swift", "x"], rg))
        #expect(ReadOnlyCommand.flagsAllowed(["--glob", "*.swift", "x"], rg))
        #expect(!ReadOnlyCommand.flagsAllowed(["--files=x"], rg), "a flag with no value given one")
        #expect(!ReadOnlyCommand.flagsAllowed(["--hidd"], rg), "abbreviations are not the option")
        #expect(ReadOnlyCommand.flagsAllowed(["--", "--hostname-bin", "x"], rg), "after --, patterns and paths")
        #expect(!ReadOnlyCommand.flagsAllowed(["x", "--search-zip"], rg), "an option after an operand is still checked")
        #expect(ReadOnlyCommand.isReadOnly("head -n20 a"))
        #expect(ReadOnlyCommand.isReadOnly("rg -- --hostname-bin x"))
        #expect(ReadOnlyCommand.isReadOnly("find . -maxdepth 2 -type f -name '*.md' -print"))
        #expect(ReadOnlyCommand.isReadOnly("ls a''=b"), "= after a real character is literal")
    }

    @Test("quotes are removed the way the shell removes them")
    func quoteRemoval() {
        #expect(ReadOnlyCommand.words("cat 'a b' \"c d\" e''f") == ["cat", "a b", "c d", "ef"])
        #expect(ReadOnlyCommand.words("cat ''") == ["cat", ""])
    }

    /// A host whose `PATH` holds only `/bin` and `/usr/bin`, with `ls`, `cat` and `rg` installed,
    /// home at `/Users/me` and the command run in `/Users/me/src/p`.
    static func lookup(path: String = "/bin:/usr/bin", cwd: String = "/Users/me/src/p",
                       home: String = "/Users/me",
                       installed: Set<String> = ["/bin/ls", "/bin/cat", "/usr/bin/rg"]) -> ReadOnlyCommand.HostLookup {
        ReadOnlyCommand.HostLookup(path: path, cwd: cwd, home: home, isExecutable: { installed.contains($0) })
    }

    @Test("the restricted PATH: only absolute entries outside home, the working directory and every sandbox-writable folder")
    func restrictedPath() {
        func path(_ program: String, cwd: String? = nil, _ lookup: ReadOnlyCommand.HostLookup = Self.lookup()) -> [String]? {
            ReadOnlyCommand.restrictedPath(program: program, cwd: cwd, lookup: lookup)
        }
        #expect(path("ls") == ["/bin", "/usr/bin"])
        #expect(path("rg") == ["/bin", "/usr/bin"])
        #expect(path("grep") == nil, "not installed on the PATH it would run with: nothing to run")
        // Unsafe entries are dropped from the run, not merely judged: the run never searches them.
        #expect(path("ls", Self.lookup(path: ".:node_modules/.bin::/bin")) == ["/bin"])
        #expect(path("ls", Self.lookup(path: "/Users/me/bin:/bin:/Users/me/.local/bin")) == ["/bin"])
        #expect(path("ls", Self.lookup(path: "/tmp/w/bin:/bin", cwd: "/tmp/w")) == ["/bin"])
        #expect(path("ls", Self.lookup(path: "/bin:/bin:/usr/bin")) == ["/bin", "/usr/bin"])
        #expect(path("rg", Self.lookup(path: "/Users/me/bin:/bin", installed: ["/Users/me/bin/rg"])) == nil,
                "found only where it may not run from")
        // A folder a sandbox mount can write is no better than home: a mount covering Homebrew drops it.
        let brew = Self.lookup(path: "/opt/homebrew/bin:/bin", installed: ["/opt/homebrew/bin/rg", "/bin/ls"])
        #expect(path("rg", brew) == ["/opt/homebrew/bin", "/bin"])
        var mounted = brew
        mounted.writableRoots = ["/opt/homebrew"]
        #expect(path("rg", mounted) == nil)
        #expect(path("ls", mounted) == ["/bin"])
        // The working directory: never home or above it.
        #expect(path("ls", cwd: "/Users/me") == nil)
        #expect(path("ls", cwd: "/Users") == nil)
        #expect(path("ls", cwd: "/") == nil)
        #expect(path("echo", cwd: "/Users/me") == nil)
        #expect(path("ls", cwd: "/tmp/elsewhere") == ["/bin", "/usr/bin"])
        // zsh's builtins need nothing on PATH.
        #expect(path("echo", Self.lookup(path: ".:/Users/me/bin")) == [])
        #expect(path("ls", Self.lookup(path: "")) == nil)
    }

    @Test("symlinks are resolved before a PATH entry or the working directory is placed")
    func restrictedPathResolvesLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("iris-606-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), bin = home.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let linkToBin = root.appendingPathComponent("innocent"), linkToHome = root.appendingPathComponent("work")
        try fm.createSymbolicLink(at: linkToBin, withDestinationURL: bin)
        try fm.createSymbolicLink(at: linkToHome, withDestinationURL: home)
        let installed: Set<String> = [linkToBin.path + "/ls", "/bin/ls"]
        let viaLink = Self.lookup(path: linkToBin.path + ":/bin", cwd: "/tmp", home: home.path, installed: installed)
        #expect(ReadOnlyCommand.restrictedPath(program: "ls", cwd: nil, lookup: viaLink) == ["/bin"],
                "a PATH entry that is a link into home is in home")
        let plain = Self.lookup(path: "/bin", cwd: "/tmp", home: home.path, installed: installed)
        #expect(ReadOnlyCommand.restrictedPath(program: "ls", cwd: linkToHome.path, lookup: plain) == nil,
                "a working directory that is a link to home is home")
    }

    @Test("the restricted environment is an allowlist: the judged PATH and a few basics, nothing inherited")
    func restrictedEnvironment() {
        let base = ["HOME": "/Users/me", "USER": "me", "LANG": "en_US.UTF-8", "LC_ALL": "C", "TERM": "xterm",
                    "PATH": "/Users/me/bin:/bin", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "ZDOTDIR": "/tmp/z",
                    "ENV": "/tmp/e", "BASH_ENV": "/tmp/b", "GIT_CONFIG_GLOBAL": "/tmp/g", "RIPGREP_CONFIG_PATH": "/tmp/r",
                    "GREP_OPTIONS": "-r", "FOO": "leak"]
        let env = ReadOnlyCommand.restrictedEnvironment(path: ["/bin", "/usr/bin"], base: base)
        #expect(env == ["HOME": "/Users/me", "USER": "me", "LANG": "en_US.UTF-8", "LC_ALL": "C", "TERM": "xterm",
                        "PATH": "/bin:/usr/bin"])
    }

    @Test("the spawn: restricted is zsh -f with exactly the judged PATH; anything else is the usual shell")
    func hostSpawn() {
        let base = ["HOME": "/Users/me", "PATH": "/Users/me/bin:/bin", "FOO": "leak"]
        let restricted = ToolExecutor.hostSpawn("ls -la", restrictedPath: ["/bin"], base: base)
        #expect(restricted.executable == "/bin/zsh")
        #expect(restricted.arguments == ["-f", "-c", "ls -la"])
        #expect(restricted.environment["PATH"] == "/bin")
        #expect(restricted.environment["FOO"] == nil)
        let usual = ToolExecutor.hostSpawn("ls -la", restrictedPath: nil, base: base)
        #expect(usual.arguments == ["-c", "ls -la"])
        #expect(usual.environment["FOO"] == "leak", "an approved command keeps the user's environment")
    }

    @Test("run for real: a planted .zshenv and an inherited variable reach the usual shell but not a restricted run")
    func restrictedRunForReal() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("iris-612-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        let planted = home.appendingPathComponent("bin")
        try fm.createDirectory(at: planted, withIntermediateDirectories: true)
        let marker = home.appendingPathComponent("zshenv-ran")
        // What the VM could leave in a home it mounts: a .zshenv that runs and puts its own ls first.
        try "touch \(marker.path)\nexport PATH=\(planted.path):$PATH\n".write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        let fakeLs = planted.appendingPathComponent("ls")
        try "#!/bin/sh\necho PLANTED\n".write(to: fakeLs, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeLs.path)
        let base = ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/bin:/usr/bin", "FOO": "leak"]

        func run(_ spawn: (executable: String, arguments: [String], environment: [String: String])) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: spawn.executable)
            process.arguments = spawn.arguments
            process.environment = spawn.environment
            process.currentDirectoryURL = fm.temporaryDirectory
            let out = Pipe()
            process.standardOutput = out
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        let command = "echo \"[$FOO]\"; ls -d /"
        let restricted = try run(ToolExecutor.hostSpawn(command, restrictedPath: ["/bin", "/usr/bin"], base: base))
        #expect(restricted.contains("[]"), "an inherited variable reached the restricted run: \(restricted)")
        #expect(!restricted.contains("PLANTED"))
        #expect(!fm.fileExists(atPath: marker.path), "the restricted run read .zshenv")

        // The control: the same plant does reach the usual shell, so the test can tell the two apart.
        let usual = try run(ToolExecutor.hostSpawn(command, restrictedPath: nil, base: base))
        #expect(usual.contains("[leak]"))
        #expect(usual.contains("PLANTED"))
        #expect(fm.fileExists(atPath: marker.path))
    }

    @Test("Vibecop's APPROVE: any command in the VM, a host read restricted, a file read, never a file write")
    func vibecopGate() {
        let host = Self.lookup()
        #expect(ReadOnlyCommand.vibecopGate(toolName: "run_command", details: "rm -f x", inSandbox: true, lookup: host) == .run)
        #expect(ReadOnlyCommand.vibecopGate(toolName: "run_command", details: "rm -f x", inSandbox: false, lookup: host) == .ask)
        #expect(ReadOnlyCommand.vibecopGate(toolName: "run_command", details: "ls -la", inSandbox: false, lookup: host)
                == .runRestricted(path: ["/bin", "/usr/bin"]))
        #expect(ReadOnlyCommand.vibecopGate(toolName: "run_command", details: "ls -la", inSandbox: false,
                                            cwd: "/Users/me", lookup: host) == .ask)
        #expect(ReadOnlyCommand.vibecopGate(toolName: "read_file", details: "/etc/hosts", inSandbox: false, lookup: host) == .run)
        #expect(ReadOnlyCommand.vibecopGate(toolName: "write_file", details: "/tmp/x", inSandbox: false, lookup: host) == .ask)
        #expect(ReadOnlyCommand.vibecopGate(toolName: "write_file", details: "/tmp/x", inSandbox: true, lookup: host) == .ask)
        #expect(ReadOnlyCommand.vibecopGate(toolName: "schedule_job", details: "x", inSandbox: false, lookup: host) == .ask)
    }

    @Test("only the gate's own approval runs restricted; a person's, the allowlist's or the VM's runs as usual")
    func onlyTheGateRestricts() {
        #expect(IrisEngine.restrictedPath(for: .vibecopRestricted(path: ["/bin"]), tool: "run_command") == ["/bin"])
        for source: AppState.ApprovalSource in [.person, .allowlist, .autoApprove, .grant, .graderCheck, .vibecop] {
            #expect(IrisEngine.restrictedPath(for: source, tool: "run_command") == nil, "\(source)")
        }
        #expect(IrisEngine.restrictedPath(for: .vibecopRestricted(path: ["/bin"]), tool: "read_file") == nil)
    }
}
