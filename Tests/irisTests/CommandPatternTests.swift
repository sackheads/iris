import Testing
import Foundation
@testable import IrisKit

/// #1102: "Always Allow" on a command saves what the command does (`git status`, `swift test`),
/// not its exact text, and a later command matches when each of its parts starts with a saved
/// prefix. Conservative: anything the tokenizer doesn't model, or a program where "any
/// arguments" means "any code", gets no prefix and keeps the exact rule.
@Suite("Always Allow saves general command rules (#1102)", .timeLimit(.minutes(1)))
struct CommandPatternTests {

    private func prefixes(_ command: String) -> [String]? {
        CommandPattern.alwaysAllowPrefixes(command)?.map { $0.joined(separator: " ") }
    }

    // MARK: What a click saves

    @Test("the shell trappings are dropped and the verb is kept")
    func derivesPrefixes() {
        #expect(prefixes("cd /tmp && git -C foo status --short | head") == ["git status"])
        #expect(prefixes("swift test --filter CommandPatternTests 2>&1 | tail -40") == ["swift test"])
        #expect(prefixes("rg -n foo Sources | sort -k3 -nr | head -15") == ["rg"])
        #expect(prefixes("ls -la /Users/bnaylor/src/iris") == ["ls"])
        #expect(prefixes("defaults read iris") == ["defaults read"])
        #expect(prefixes("npm run build -- --watch") == ["npm run build"])
        #expect(prefixes("gh pr view 1131 --comments") == ["gh pr view"])
        #expect(prefixes("swift build && swift test") == ["swift build", "swift test"])
        #expect(prefixes("git status; git status") == ["git status"])
        #expect(prefixes("tailscale status --json") == ["tailscale status"], "an unknown tool keeps a read-only verb, never the program alone")
        #expect(prefixes("echo --- && git log --oneline -5 >/dev/null") == ["git log"])
    }

    @Test("no prefix for code runners, network tools, destructive tools, unlisted subcommands or non-read verbs")
    func refusesDangerousPrefixes() {
        for command in [
            // Verb-shaped fixtures (`list` is in unlistedReadVerbs) so `neverGeneralized` is what refuses them:
            "curl list", "rm list", "sh list", "bash list", "python3 list", "env list", "sudo list",
            "curl -s -H \"Authorization: Bearer ya29.secret\" https://example.com",
            "python3 -c 'print(1)'", "bash scripts/x.sh", "env FOO=1 ls", "xargs rm", "sudo ls",
            "rm -rf build", "find . -name x", "make lint", "npx something", "sed -i s/a/b/ f",
            // Git subcommands that run programs, destroy work, or are off the list:
            "git push origin main", "git config core.pager evil", "git -c core.pager=evil log",
            "git fetch --upload-pack=evil", "git grep foo", "git branch", "git checkout main",
            "git restore --staged foo", "git stash", "git worktree list", "git remote -v",
            // Git denied options, including abbreviations and -O<pager>:
            "git log --ext-diff", "git diff --output=x", "git log --textconv", "git log --out=x",
            "git diff --ext", "/usr/bin/git log --output=/Users/x/.zshrc",
            // Bare-program write/exec tools no longer in wholePrograms:
            "ls | sort -o evil.txt", "sort -o evil.txt f", "tree -o /tmp/x", "touch ~/.zshenv",
            // Nested CLIs with non-read verbs:
            "gcloud compute instances list", "terraform apply",
            // Unlisted subcommands and path-qualified programs:
            "npm install", "gh api /user", "swift package plugin x",
            "ffmpeg -i in.mp4 out.mp4", "scripts/test-filter.sh Foo", "./build.sh",
            "/usr/bin/git status", "/tmp/evil/ls -la", "/tmp/evil/git status", "/tmp/evil/swift test",
            "FOO=1 make", "defaults write com.x y 1", "kubectl exec -it pod sh",
        ] {
            #expect(prefixes(command) == nil, "\(command)")
        }
    }

    @Test("anything the tokenizer doesn't model gets no prefix")
    func refusesShellFeatures() {
        for command in [
            "git status $(rm -rf ~)", "git status `id`", "git log > out.txt", "git log >> out.txt",
            "git status &", "(git status)", "git status *", "git log \"$HOME\"", "ls ~/{a,b}",
            "git status\nrm -rf ~", "cat < /etc/passwd", "git status 1>&2", "git status |& tee x",
            "git status &&", "&& git status", "git status ;; ls",
        ] {
            #expect(CommandPattern.alwaysAllowPrefixes(command) == nil, "\(command)")
        }
    }

    @Test("a command of ride-alongs alone gets no prefix")
    func rideAlongsAlone() {
        #expect(prefixes("cd /tmp && pwd") == nil)
        #expect(prefixes("echo hi") == nil)
    }

    @Test("a pipe filter rides along only when it reads nothing but its input")
    func pipeFilters() {
        #expect(prefixes("git log | grep fix") == ["git log"])
        #expect(prefixes("git log | head -n 5") == ["git log"])
        // Each of these names a file to read: it is a part of its own that needs a rule.
        #expect(prefixes("git log | grep fix /etc/passwd") == ["git log", "grep"])
        #expect(prefixes("git log | head /etc/passwd") == ["git log", "head"])
        #expect(prefixes("git log | grep -e fix /etc/passwd") == ["git log", "grep"])
        #expect(prefixes("git log | grep -f patterns") == ["git log", "grep"])
        // Not after a pipe, a filter is an ordinary read.
        #expect(prefixes("grep -r foo Sources") == ["grep"])
    }

    // MARK: What a rule matches

    private func matches(_ command: String, _ rules: [String], workspace: String? = "/tmp/proj") -> Bool {
        CommandPattern.matchedPrefixes(command, prefixes: rules.map { $0.split(separator: " ").map(String.init) },
                                       workspace: workspace) != nil
    }

    @Test("a prefix matches later commands with any plain arguments and trappings inside the workspace")
    func prefixMatches() {
        #expect(matches("git status", ["git status"]))
        #expect(matches("cd /tmp/proj && git --no-pager status -sb 2>&1 | head -20", ["git status"], workspace: "/tmp/proj"))
        #expect(matches("cd sub && git -C nested status", ["git status"], workspace: "/tmp/proj"))
        #expect(matches("swift test --filter Other 2>&1 | tail -80", ["swift test"]))
        #expect(matches("swift build && swift test", ["swift test", "swift build"]))
        #expect(matches("cat README.md", ["cat"], workspace: "/tmp/proj"))
        #expect(matches("cat Sources/a.swift", ["cat"], workspace: "/tmp/proj"))
        #expect(matches("rg -n foo Sources", ["rg"], workspace: "/tmp/proj"))
        #expect(matches("rg -e foo Sources", ["rg"], workspace: "/tmp/proj"))
        #expect(matches("grep -rn /outside/pattern Sources", ["grep"], workspace: "/tmp/proj"))
        #expect(matches("rg --files Sources", ["rg"], workspace: "/tmp/proj"))
        #expect(matches("ls -la", ["ls"], workspace: "/tmp/proj"))
    }

    @Test("every part must match, flags stay read-only for bare programs, and cd/-C stay in workspace")
    func prefixRefuses() {
        #expect(!matches("git status && git push", ["git status"]))
        #expect(!matches("git statusx", ["git status"]))
        #expect(!matches("git stash", ["git status"]))
        #expect(!matches("git status $(id)", ["git status"]))
        #expect(!matches("git status > out", ["git status"]))
        #expect(!matches("git -c core.pager=evil status", ["git status"]))
        #expect(!matches("git log --output=/tmp/x", ["git log"]))
        #expect(!matches("git log --out=/tmp/x", ["git log"]))
        #expect(!matches("git log --ext-diff", ["git log"]))
        #expect(!matches("git log --textconv", ["git log"]))
        #expect(!matches("/usr/bin/git log --output=/Users/x/.zshrc", ["git log"]))
        #expect(!matches("/usr/bin/git status -sb", ["git status"]))
        #expect(!matches("/tmp/evil/ls -la", ["ls"]))
        #expect(!matches("/tmp/evil/git status", ["git status"]))
        #expect(!matches("/tmp/evil/swift test", ["swift test"]))
        #expect(!matches("git grep -O/tmp/x.sh foo", ["git grep"]))
        #expect(!matches("git grep -Osh foo", ["git grep"]))
        #expect(!matches("git grep --open=/tmp/x.sh foo", ["git grep"]))
        // Bare-program prefixes still enforce ReadOnlyCommand's flag allowlists at match time:
        #expect(!matches("file -C -m /tmp/x", ["file"]))
        #expect(!matches("rg --pre=evil foo", ["rg"]))
        #expect(!matches("rg -z foo", ["rg"]))
        // Bare-program file reads are confined to the workspace:
        #expect(!matches("cat ~/.ssh/id_rsa", ["cat"], workspace: "/tmp/proj"))
        #expect(!matches("cat /etc/passwd", ["cat"], workspace: "/tmp/proj"))
        #expect(!matches("cat ../secret", ["cat"], workspace: "/tmp/proj"))
        #expect(!matches("cat README.md", ["cat"], workspace: nil))
        #expect(!matches("ls /etc", ["ls"], workspace: "/tmp/proj"))
        #expect(!matches("ls -la", ["ls"], workspace: nil))
        #expect(!matches("rg -n foo /etc", ["rg"], workspace: "/tmp/proj"))
        #expect(!matches("rg -e foo /etc", ["rg"], workspace: "/tmp/proj"))
        #expect(!matches("rg --files /etc", ["rg"], workspace: "/tmp/proj"))
        #expect(!matches("rg -n --files /etc", ["rg"], workspace: "/tmp/proj"))
        #expect(!matches("grep -f /etc/passwd foo", ["grep"], workspace: "/tmp/proj"))
        #expect(!matches("grep -f p /etc/passwd", ["grep"], workspace: "/tmp/proj"))
        #expect(!matches("grep -rf p /etc", ["grep"], workspace: "/tmp/proj"))
        #expect(!matches("fgrep -f p /etc/passwd", ["fgrep"], workspace: "/tmp/proj"))
        #expect(!matches("grep -fp /etc/passwd", ["grep"], workspace: "/tmp/proj"))
        // cd and git -C cannot carry a rule outside the workspace (or with no workspace):
        #expect(!matches("cd /tmp/evil && swift test", ["swift test"], workspace: "/tmp/proj"))
        #expect(!matches("cd /tmp/evil && swift test", ["swift test"], workspace: nil))
        #expect(!matches("cd .. && swift test", ["swift test"], workspace: "/tmp/proj"))
        #expect(!matches("git -C /tmp/evil status", ["git status"], workspace: "/tmp/proj"))
        #expect(!matches("git -C /tmp/evil status", ["git status"], workspace: nil))
        #expect(!matches("cd /tmp/proj && pwd", ["git status"], workspace: "/tmp/proj"), "ride-alongs alone are not approved by a rule")
        #expect(!matches("cd /elsewhere && scripts/x.sh", ["scripts/x.sh"], workspace: "/elsewhere"), "a relative program never matches a prefix")
        #expect(!matches("git status", []))
    }

    // MARK: Through PermissionManager

    private func manager() throws -> (PermissionManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1102-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        return (PermissionManager(paths: paths), root)
    }

    @Test("a saved prefix rule approves attended non-guest calls, never unattended or guest-origin ones")
    func attendedOnly() throws {
        let (permissions, root) = try manager()
        defer { try? FileManager.default.removeItem(at: root) }
        permissions.allowGlobally(PermissionRule.forAlwaysAllow(toolName: "run_command",
                                                                details: "cd /tmp && git status --short | head"))
        let match = permissions.match(toolName: "run_command", details: "git status -sb", workspace: nil)
        #expect(match == AllowMatch(scope: .global, rule: PermissionRule(toolName: "run_command", details: "git status", match: .prefix)))
        #expect(!permissions.isAllowed(toolName: "run_command", details: "git status -sb", workspace: nil, isBackground: true))
        #expect(!permissions.isAllowed(toolName: "run_command", details: "git status", workspace: nil, isBackground: true),
                "not even the bare prefix's text, which an exact compare would have matched")
        #expect(!permissions.isAllowed(toolName: "run_command", details: "git status -sb", workspace: nil, isGuestOrigin: true),
                "a guest-origin turn must not use a saved prefix rule")
        #expect(!permissions.isAllowed(toolName: "run_command", details: "git push", workspace: nil))
    }

    @Test("AppState's approval ladder skips prefix rules on a guest-origin turn (#1102)")
    @MainActor
    func appStateGuestOriginSkipsPrefix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1102-ladder-\(UUID().uuidString)")
        let paths = IrisPaths(root: root.appendingPathComponent("iris-home"))
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: paths)
        state.permissions.allowGlobally(PermissionRule.forAlwaysAllow(toolName: "run_command", details: "git status"))

        let ordinaryId = state.createNewConversation(isBackground: false, select: false)
        let ordinarySource = await state.requestApprovalSource(
            toolName: "run_command", details: "git status -sb", conversationId: ordinaryId, vibecopEnabled: false)
        #expect(ordinarySource == .allowlist(AllowMatch(
            scope: .global, rule: PermissionRule(toolName: "run_command", details: "git status", match: .prefix))))

        let guestId = state.createNewConversation(isBackground: false, select: false)
        state.markGuestOriginTurn(guestId)
        let askTask = Task { @MainActor in
            await state.requestApprovalSource(
                toolName: "run_command", details: "git status -sb", conversationId: guestId, vibecopEnabled: false)
        }
        for _ in 0..<200 where !state.pendingApprovals.contains(where: { $0.conversationId == guestId }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let pending = try #require(state.pendingApprovals.first(where: { $0.conversationId == guestId }))
        state.resolveApproval(id: pending.id, .approve)
        let guestSource = try await value(of: askTask)
        #expect(guestSource == .person)
    }

    @Test("a chain can match one global rule and one project rule")
    func globalAndProject() throws {
        let (permissions, root) = try manager()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("proj").path
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        permissions.allowGlobally(PermissionRule.forAlwaysAllow(toolName: "run_command", details: "swift build"))
        permissions.allowInProject(PermissionRule.forAlwaysAllow(toolName: "run_command", details: "swift test"), workspace: workspace)
        let match = permissions.match(toolName: "run_command", details: "swift build && swift test --filter X", workspace: workspace)
        #expect(match?.scope == .project)
        #expect(match?.rule?.details == "swift build; swift test")
        #expect(!permissions.isAllowed(toolName: "run_command", details: "swift build && swift test", workspace: nil))
    }

    @Test("a command with no general rule still saves the exact command, and a file rule is untouched")
    func exactFallback() {
        let curl = "curl -s https://example.com"
        #expect(PermissionRule.forAlwaysAllow(toolName: "run_command", details: curl)
                == [PermissionRule(toolName: "run_command", details: curl)])
        #expect(PermissionRule.forAlwaysAllow(toolName: "read_file", details: "/tmp/x")
                == [PermissionRule(toolName: "read_file", details: "/tmp/x")])
    }

    @Test("old rule files read as exact, and a rule kind from a newer build neither breaks the file nor matches")
    func persistence() throws {
        let old = #"[{"toolName":"run_command","details":"pwd"}]"#
        let rules = try JSONDecoder().decode([PermissionRule].self, from: Data(old.utf8))
        #expect(rules == [PermissionRule(toolName: "run_command", details: "pwd")])
        #expect(rules[0].isExact)
        // An exact rule is written without the key, so an older build reads it unchanged.
        let written = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
        #expect(!written.contains("match"))

        let (permissions, root) = try manager()
        defer { try? FileManager.default.removeItem(at: root) }
        let future = #"[{"toolName":"read_file","details":"/tmp","match":"directory"},{"toolName":"run_command","details":"pwd"}]"#
        try Data(future.utf8).write(to: permissions.paths.permissionsJSON)
        #expect(!permissions.isAllowed(toolName: "read_file", details: "/tmp", workspace: nil))
        #expect(permissions.isAllowed(toolName: "run_command", details: "pwd", workspace: nil))
        permissions.allowGlobally(toolName: "run_command", details: "ls")
        let saved = String(decoding: try Data(contentsOf: permissions.paths.permissionsJSON), as: UTF8.self)
        #expect(saved.contains("\"directory\""), "saving keeps the newer kind as it was")
    }

    @Test("the pill's record of a prefix rule says it covers more than its text")
    func pillRecord() {
        let match = AllowMatch(scope: .global, rule: PermissionRule(toolName: "run_command", details: "swift build; swift test", match: .prefix))
        #expect(ToolApproval(.allowlist(match)).detail == "run_command swift build …; swift test …")
    }

    @Test("the banner says what Always Allow saves")
    @MainActor
    func bannerSummary() {
        #expect(ApprovalBannerView.alwaysAllowSummary(PermissionRule.forAlwaysAllow(toolName: "run_command", details: "git status | head"))
                == "Always Allow saves: `git status …` (any arguments; attended chats only).")
        #expect(ApprovalBannerView.alwaysAllowSummary(PermissionRule.forAlwaysAllow(toolName: "run_command", details: "rm -rf x"))?
                    .contains("exact command") == true)
        #expect(ApprovalBannerView.alwaysAllowSummary(PermissionRule.forAlwaysAllow(toolName: "read_file", details: "/x")) == nil)
    }
}
