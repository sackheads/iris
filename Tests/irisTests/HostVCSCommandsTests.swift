import Testing
import Foundation
@testable import IrisKit

/// #1435 slice 3 (Brian's F5): which host commands are the person's alone, and that nothing else approves them.
@Suite("Host VCS commands are the person's alone (#1435 slice 3)", .timeLimit(.minutes(1)))
struct HostVCSCommandsTests {
    @Test("gh, git by path or through a wrapper, git's transports and its config-changing options need the person", arguments: [
        "gh pr create", "gh auth token", "/opt/homebrew/bin/gh api user", "env gh pr view 1",
        "git push origin main", "git fetch", "git pull --rebase", "git clone https://github.com/a/b", "git ls-remote origin",
        "git remote add evil x", "git submodule update", "git -C sub push", "git --no-pager fetch",
        "/usr/bin/git status", "./git status", "env git status", "command git log", "xargs git status", "sudo git status",
        "FOO=1 git push", "git -c credential.helper=osxkeychain status", "git --config-env=core.pager=X log",
        "git --exec-path=/tmp status", "git --git-dir=/x status", "cd a && git push", "ls | git push",
        "echo $(git push)", "x=`gh auth token`",
        // dev-3's #1453 review: an assignment can undo the strip, and the credential helpers read the keychain.
        "GIT_CONFIG_COUNT=0 git status", "GIT_CONFIG_PARAMETERS=x git log", "GIT_DIR=/x git status", "GIT_EXEC_PATH=/tmp git status",
        "GIT_CONFIG_COUNT=0 git credential fill", "git credential fill", "git credential-osxkeychain get",
        "git-credential-osxkeychain get", "/usr/libexec/git-core/git-credential-store get",
        "git config alias.x '!env -u GIT_CONFIG_COUNT git push'", "git config credential.helper osxkeychain",
        "git config --local include.path /tmp/x", "git config core.sshCommand ssh",
        // The planner's widening: keychain secrets and every git variable, wherever it's set or unset.
        "security find-internet-password -s github.com -w", "security find-generic-password -s gh:github.com -w",
        "security dump-keychain -d", "security export -k login.keychain", "/usr/bin/security find-key",
        "export GIT_CONFIG_COUNT=0; git status", "unset GIT_CONFIG_COUNT && git status", "env -u GIT_CONFIG_COUNT git status",
        "GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=osxkeychain git status", "git -c credential.helper=x fetch",
        "git --config-env=credential.helper=X status", "echo $GIT_CONFIG_COUNT",
    ])
    func needsPerson(_ command: String) {
        #expect(HostVCSCommands.needsPerson(command), Comment(rawValue: command))
    }

    @Test("ordinary local git, and words that only look like gh or git, take the usual ladder", arguments: [
        "git status", "git commit -m x", "git log --oneline", "git -C sub status", "git add -A", "git rebase --continue",
        "git worktree add ../iris-x", "swift build", "grep -r gh docs", "ls ghost", "cat .github/x", "github-cli-docs",
        "echo pushing", "git diff push.txt", "security list-keychains", "security find-identity -v -p codesigning", "git config user.name x", "git config --get remote.origin.url",
    ])
    func usualLadder(_ command: String) {
        #expect(!HostVCSCommands.needsPerson(command), Comment(rawValue: command))
    }

    @Test("an allowlist rule, Vibecop or YOLO never approves one; the person is asked, Always allow is not offered")
    @MainActor
    func ladderAsksThePerson() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-hostvcs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: root.appendingPathComponent("iris-home")))
        state.permissions.allowGlobally([PermissionRule(toolName: "run_command", details: "git fetch", match: .prefix),
                                         PermissionRule(toolName: "run_command", details: "gh pr create", match: .exact)])
        let id = state.createNewConversation(isBackground: false, select: false)
        state.setYoloMode(true, for: id)
        for command in ["git fetch origin", "gh pr create"] {
            let task = Task { await state.requestApprovalSource(toolName: "run_command", details: command, workspace: root.path,
                                                                 conversationId: id, vibecopEnabled: false, isOwner: true) }
            let deadline = TestClock.deadline(5)
            while state.pendingApprovals.isEmpty, TestClock.now() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            let pending = try #require(state.pendingApprovals.first, "\(command): the person was asked")
            #expect(pending.humanOnly, "\(command): no Always allow")
            state.denyPendingApprovals(for: id)
            #expect(try await value(of: task) == nil)
        }
        // Control: an ordinary local command the rule covers is still allowed by it.
        state.permissions.allowGlobally([PermissionRule(toolName: "run_command", details: "git status", match: .prefix)])
        #expect(await state.requestApprovalSource(toolName: "run_command", details: "git status --short", workspace: root.path,
                                                  conversationId: id, vibecopEnabled: false, isOwner: true) != nil)
    }
}
