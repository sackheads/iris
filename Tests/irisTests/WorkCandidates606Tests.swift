import Testing
@testable import IrisKit

/// work's adversarial pass on #606 at 0e69fd28, kept as a permanent table: 115 candidates, run
/// through real `zsh -c "<cmd>" </dev/null | cat` in a scratch directory with marker scripts. `old`
/// is what the blocklist version said, `zsh` what the shell actually did. Under the flag allowlists
/// a candidate is read-only only if it reads and every option it uses is listed; every row that
/// EXECUTED or EXPANDED, and every git row, is may-write.
@Suite("work's #606 candidates under the flag allowlists")
struct WorkCandidates606Tests {
    struct Row: CustomTestStringConvertible, Sendable {
        let command: String
        let readOnly: Bool
        let old: Bool
        let zsh: String
        var testDescription: String { command.debugDescription }
    }

    static let rows: [Row] = [
        Row(command: "rg --hostname-bin=/tmp/x --hyperlink-format=default foo", readOnly: false, old: true, zsh: "EXECUTED the program (marker)"),
        Row(command: "rg --hostname-bin /tmp/x foo", readOnly: false, old: true, zsh: "EXECUTED the program, no hyperlink flag"),
        Row(command: "rg -z foo", readOnly: false, old: true, zsh: "EXECUTED PATH `gzip -d -c` (scratch gzip first on PATH)"),
        Row(command: "rg --search-zip foo", readOnly: false, old: true, zsh: "not run (same as -z)"),
        Row(command: "rg -zl foo", readOnly: false, old: true, zsh: "not run (contains -z)"),
        Row(command: "rg --pre=x foo", readOnly: false, old: false, zsh: "-"),
        Row(command: "rg --pr=x foo", readOnly: false, old: true, zsh: "\"unrecognized flag --pr\", nothing executed"),
        Row(command: "rg -P foo", readOnly: false, old: true, zsh: "not run (read)"),
        Row(command: "rg --hyperlink-format=default foo", readOnly: false, old: true, zsh: "not run (read)"),
        Row(command: "rg --no-config foo", readOnly: false, old: true, zsh: "not run (read)"),
        Row(command: "rg --type-add=x:*.x foo", readOnly: false, old: false, zsh: "-"),
        Row(command: "file -z x.Z", readOnly: false, old: true, zsh: "EXECUTED PATH gzip -cd / uncompress -c; lzip -cd on .lz; zstd -cd on .zst"),
        Row(command: "file -Z x", readOnly: false, old: true, zsh: "not run (same path)"),
        Row(command: "file -C", readOnly: false, old: false, zsh: "-"),
        Row(command: "file -bC", readOnly: false, old: false, zsh: "-"),
        Row(command: "file --compile", readOnly: false, old: false, zsh: "-"),
        Row(command: "file --comp", readOnly: false, old: false, zsh: "-"),
        Row(command: "file -m x y", readOnly: false, old: true, zsh: "not run (reads magic)"),
        Row(command: "file -zs x", readOnly: false, old: true, zsh: "not run (contains -z)"),
        Row(command: "git status", readOnly: false, old: true, zsh: "rewrites .git/index; EXECUTED fsmonitor when configured (incl. via include.path)"),
        Row(command: "git describe --dirty", readOnly: false, old: true, zsh: "EXECUTED fsmonitor (as --dirty --always)"),
        Row(command: "git log --show-signature", readOnly: false, old: true, zsh: "EXECUTED gpg.program; real gpg --verify with no config"),
        Row(command: "git show --show-signature", readOnly: false, old: true, zsh: "EXECUTED gpg.program"),
        Row(command: "git log --format=%G?", readOnly: false, old: false, zsh: "- (the quoted form '%G?' would pass and verify)"),
        Row(command: "git log -p", readOnly: false, old: true, zsh: "EXECUTED textconv; not diff.external"),
        Row(command: "git diff", readOnly: false, old: true, zsh: "EXECUTED fsmonitor, diff.external, textconv"),
        Row(command: "git diff --textconv", readOnly: false, old: true, zsh: "not run"),
        Row(command: "git show --textconv", readOnly: false, old: true, zsh: "not run (plain show EXECUTED textconv)"),
        Row(command: "git log --output=x", readOnly: false, old: false, zsh: "-"),
        Row(command: "git log --out=x", readOnly: false, old: false, zsh: "-"),
        Row(command: "git log --o=x", readOnly: false, old: false, zsh: "-"),
        Row(command: "git diff --ext-diff", readOnly: false, old: false, zsh: "-"),
        Row(command: "git diff --ext", readOnly: false, old: false, zsh: "-"),
        Row(command: "git diff --no-index a b", readOnly: false, old: true, zsh: "not run"),
        Row(command: "git blame --contents=x y", readOnly: false, old: true, zsh: "not run (plain blame EXECUTED textconv)"),
        Row(command: "git log --paginate", readOnly: false, old: false, zsh: "-"),
        Row(command: "git log --pag", readOnly: false, old: false, zsh: "-"),
        Row(command: "git branch", readOnly: false, old: true, zsh: "not run"),
        Row(command: "git branch -a", readOnly: false, old: true, zsh: "not run"),
        Row(command: "git branch --show-current", readOnly: false, old: true, zsh: "not run"),
        Row(command: "git branch x", readOnly: false, old: false, zsh: "-"),
        Row(command: "git branch --list x", readOnly: false, old: false, zsh: "- (work: wrongly strict)"),
        Row(command: "git status --porcelain", readOnly: false, old: true, zsh: "EXECUTED fsmonitor"),
        Row(command: "git rev-parse --git-path hooks", readOnly: false, old: true, zsh: "not run"),
        Row(command: "git log -c", readOnly: false, old: true, zsh: "not run"),
        Row(command: "git log --no-walk", readOnly: false, old: true, zsh: "not run"),
        Row(command: "git log --exec=x", readOnly: false, old: true, zsh: "not run (git errors)"),
        Row(command: "git diff --output-indicator-new=x", readOnly: false, old: false, zsh: "-"),
        Row(command: "git describe --broken", readOnly: false, old: true, zsh: "not run (refreshes index)"),
        Row(command: "git ls-files --others", readOnly: false, old: true, zsh: "EXECUTED fsmonitor (plain ls-files)"),
        Row(command: "git shortlog", readOnly: false, old: true, zsh: "not run"),
        Row(command: "git blame -S x y", readOnly: false, old: true, zsh: "not run"),
        Row(command: "git diff -Ox", readOnly: false, old: true, zsh: "not run"),
        Row(command: "git log -g", readOnly: false, old: true, zsh: "not run"),
        Row(command: "git -c core.pager=x log", readOnly: false, old: false, zsh: "-"),
        Row(command: "git -C /tmp log", readOnly: false, old: false, zsh: "-"),
        Row(command: "git --no-pager log", readOnly: false, old: false, zsh: "-"),
        Row(command: "git log --ext-diff", readOnly: false, old: false, zsh: "-"),
        Row(command: "GIT_EXTERNAL_DIFF=x git diff", readOnly: false, old: false, zsh: "-"),
        Row(command: "PAGER=x git log", readOnly: false, old: false, zsh: "-"),
        Row(command: "git 'status'", readOnly: false, old: true, zsh: "not run"),
        Row(command: "'git' status", readOnly: false, old: true, zsh: "not run"),
        Row(command: "\"git\" status", readOnly: false, old: true, zsh: "not run"),
        Row(command: "find . -name x", readOnly: true, old: true, zsh: "not run"),
        Row(command: "find . -delete", readOnly: false, old: false, zsh: "-"),
        Row(command: "find . '-exec' ls ';'", readOnly: false, old: false, zsh: "-"),
        Row(command: "find . -execdir ls '{}' ';'", readOnly: false, old: false, zsh: "-"),
        Row(command: "find . -fls x", readOnly: false, old: false, zsh: "-"),
        Row(command: "find . -fprint x", readOnly: false, old: false, zsh: "-"),
        Row(command: "find -f . -ls", readOnly: false, old: true, zsh: "not run"),
        Row(command: "find . -newer x", readOnly: true, old: true, zsh: "not run"),
        Row(command: "find . -print0", readOnly: true, old: true, zsh: "not run"),
        Row(command: "ls ~", readOnly: true, old: true, zsh: "not run"),
        Row(command: "ls ~root", readOnly: true, old: true, zsh: "not run"),
        Row(command: "ls ~+", readOnly: true, old: true, zsh: "expands to $PWD"),
        Row(command: "ls ~-", readOnly: true, old: true, zsh: "expands to $OLDPWD"),
        Row(command: "ls ~1", readOnly: true, old: true, zsh: "zsh error, nothing run"),
        Row(command: "ls =ls", readOnly: false, old: false, zsh: "-"),
        Row(command: "ls ''=ls", readOnly: false, old: true, zsh: "EXPANDED to /bin/ls (guard bypass)"),
        Row(command: "ls \"\"=ls", readOnly: false, old: true, zsh: "EXPANDED to /bin/ls"),
        Row(command: "ls a=b", readOnly: true, old: true, zsh: "literal"),
        Row(command: "ls 'a'b", readOnly: true, old: true, zsh: "ab"),
        Row(command: "ls a'b'c", readOnly: true, old: true, zsh: "not run (abc)"),
        Row(command: "ls ^x", readOnly: false, old: false, zsh: "-"),
        Row(command: "ls x#", readOnly: false, old: false, zsh: "-"),
        Row(command: "ls *(e:ls:)", readOnly: false, old: false, zsh: "-"),
        Row(command: "ls x(e:ls:)", readOnly: false, old: false, zsh: "-"),
        Row(command: "echo ~=ls", readOnly: true, old: true, zsh: "literal"),
        Row(command: "echo a~b", readOnly: true, old: true, zsh: "literal"),
        Row(command: "ls -- -x", readOnly: true, old: true, zsh: "not run"),
        Row(command: "echo -e x", readOnly: true, old: true, zsh: "not run (builtin)"),
        Row(command: "echo '$(ls)'", readOnly: true, old: true, zsh: "literal $(ls)"),
        Row(command: "echo \"x\"y", readOnly: true, old: true, zsh: "xy"),
        Row(command: "ls 'x y'", readOnly: true, old: true, zsh: "not run"),
        Row(command: "Ls", readOnly: false, old: false, zsh: "-"),
        Row(command: "LS", readOnly: false, old: false, zsh: "-"),
        Row(command: "/bin/ls", readOnly: false, old: false, zsh: "-"),
        Row(command: "ls\tx", readOnly: false, old: false, zsh: "-"),
        Row(command: "ls\nrm x", readOnly: false, old: false, zsh: "-"),
        Row(command: "ls; rm x", readOnly: false, old: false, zsh: "-"),
        Row(command: "ls && rm x", readOnly: false, old: false, zsh: "-"),
        Row(command: "ls | sh", readOnly: false, old: false, zsh: "-"),
        Row(command: "cat x > y", readOnly: false, old: false, zsh: "-"),
        Row(command: "tail -f x", readOnly: false, old: true, zsh: "not run (never exits until timeout)"),
        Row(command: "head -c 1 /dev/zero", readOnly: true, old: true, zsh: "not run"),
        Row(command: "du -A .", readOnly: false, old: true, zsh: "not run"),
        Row(command: "stat -f %N x", readOnly: false, old: false, zsh: "- (work: wrongly strict)"),
        Row(command: "which -a ls", readOnly: true, old: true, zsh: "not run (builtin)"),
        Row(command: "df -h", readOnly: true, old: true, zsh: "not run"),
        Row(command: "cat /dev/urandom", readOnly: true, old: true, zsh: "not run (unbounded output)"),
        Row(command: "grep -Z foo x", readOnly: false, old: true, zsh: "not run (BSD -Z decompresses via internal libz; unverified)"),
        Row(command: "grep --null foo x", readOnly: false, old: true, zsh: "not run"),
        Row(command: "egrep -r foo .", readOnly: true, old: true, zsh: "not run"),
        Row(command: "uname -a", readOnly: true, old: true, zsh: "not run"),
        Row(command: "whoami", readOnly: true, old: true, zsh: "not run"),
    ]

    @Test("each candidate gets its verdict", arguments: rows)
    func verdict(row: Row) {
        #expect(ReadOnlyCommand.isReadOnly(row.command) == row.readOnly, "zsh: \(row.zsh)")
    }

    @Test("all 115 are here, and nothing that executed, expanded or ran git is read-only")
    func coverage() {
        #expect(Self.rows.count == 115)
        for row in Self.rows where row.zsh.contains("EXECUTED") || row.zsh.contains("EXPANDED") || row.command.contains("git") {
            #expect(!row.readOnly, "\(row.command.debugDescription)")
        }
    }
}
