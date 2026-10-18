import Testing
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
        // rg's preprocessor and file's compiler, abbreviated too.
        "rg --pre sh x", "rg --pre=sh x", "rg --pre-glob x y", "file -C -m m", "file -zC x", "file --compile",
        "file --comp",
        // Nothing at all.
        "", "   ",
    ]

    static let allowed: [String] = [
        "ls", "ls -la", "ls -la ~/src", "ls ~", "cat README.md", "cat 'a file.txt'", "cat \"a file.txt\"",
        "head -n 20 Sources/a.swift", "tail -n 5 log.txt", "wc -l a b", "pwd", "which swift", "stat a",
        "du -sh .", "df -h", "grep -rn foo Sources", "grep -rn 'foo bar' .", "grep -E \"a|b\" f", "egrep x f",
        "basename /a/b", "dirname /a/b", "whoami", "uname -a", "echo hello", "file a", "file -b a", "rg foo",
        "rg -n 'x' Sources", "find . -name '*.swift'", "find . -type f -newer a", "git status",
        "git status --porcelain", "git log --oneline -5", "git diff", "git diff HEAD~1 -- a", "git show HEAD",
        "git rev-parse HEAD", "git ls-files", "git blame a", "git describe --tags", "git branch", "git branch -a",
        "git branch --show-current", "git diff --exit-code", "git log --format='%H'", "ls  -la", " ls ",
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

    @Test("quotes are removed the way the shell removes them")
    func quoteRemoval() {
        #expect(ReadOnlyCommand.words("cat 'a b' \"c d\" e''f") == ["cat", "a b", "c d", "ef"])
        #expect(ReadOnlyCommand.words("cat ''") == ["cat", ""])
    }

    @Test("Vibecop may approve: any command in the VM, only a read on the host, never a file write")
    func vibecopMayApprove() {
        #expect(ReadOnlyCommand.vibecopMayApprove(toolName: "run_command", details: "rm -f x", inSandbox: true))
        #expect(!ReadOnlyCommand.vibecopMayApprove(toolName: "run_command", details: "rm -f x", inSandbox: false))
        #expect(ReadOnlyCommand.vibecopMayApprove(toolName: "run_command", details: "ls -la", inSandbox: false))
        #expect(ReadOnlyCommand.vibecopMayApprove(toolName: "read_file", details: "/etc/hosts", inSandbox: false))
        #expect(!ReadOnlyCommand.vibecopMayApprove(toolName: "write_file", details: "/tmp/x", inSandbox: false))
        #expect(!ReadOnlyCommand.vibecopMayApprove(toolName: "write_file", details: "/tmp/x", inSandbox: true))
        #expect(!ReadOnlyCommand.vibecopMayApprove(toolName: "schedule_job", details: "x", inSandbox: false))
    }
}
