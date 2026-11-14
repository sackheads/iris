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
        #expect(prefixes("ps -Ao pid,ppid,%cpu,%mem,etime,comm | sort -k3 -nr | head -15") == ["ps"])
        #expect(prefixes("ls -la /Users/bnaylor/src/iris") == ["ls"])
        #expect(prefixes("defaults read iris") == ["defaults read"])
        #expect(prefixes("npm run build -- --watch") == ["npm run build"])
        #expect(prefixes("gh pr view 1131 --comments") == ["gh pr view"])
        #expect(prefixes("swift build && swift test") == ["swift build", "swift test"])
        #expect(prefixes("git status; git status") == ["git status"])
        #expect(prefixes("tailscale status --json") == ["tailscale status"], "an unknown tool keeps its verb, never the program alone")
        #expect(prefixes("echo --- && git log --oneline -5 >/dev/null") == ["git log"])
    }

    @Test("no prefix for code runners, network tools, destructive tools or unlisted subcommands")
    func refusesDangerousPrefixes() {
        for command in [
            "curl -s -H \"Authorization: Bearer ya29.secret\" https://example.com",
            "python3 -c 'print(1)'", "bash scripts/x.sh", "env FOO=1 ls", "xargs rm", "sudo ls",
            "rm -rf build", "find . -name x", "make lint", "npx something", "sed -i s/a/b/ f",
            "git push origin main", "git config core.pager evil", "git -c core.pager=evil log",
            "git fetch --upload-pack=evil", "npm install", "gh api /user", "swift package plugin x",
            "ffmpeg -i in.mp4 out.mp4", "scripts/test-filter.sh Foo", "./build.sh", "FOO=1 make",
            "defaults write com.x y 1", "kubectl exec -it pod sh",
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

    private func matches(_ command: String, _ rules: [String]) -> Bool {
        CommandPattern.matchedPrefixes(command, prefixes: rules.map { $0.split(separator: " ").map(String.init) }) != nil
    }

    @Test("a prefix matches later commands with any plain arguments and trappings")
    func prefixMatches() {
        #expect(matches("git status", ["git status"]))
        #expect(matches("cd ~/src/iris && git --no-pager status -sb 2>&1 | head -20", ["git status"]))
        #expect(matches("swift test --filter Other 2>&1 | tail -80", ["swift test"]))
        #expect(matches("swift build && swift test", ["swift test", "swift build"]))
    }

    @Test("every part must match, and the arguments stay plain")
    func prefixRefuses() {
        #expect(!matches("git status && git push", ["git status"]))
        #expect(!matches("git statusx", ["git status"]))
        #expect(!matches("git stash", ["git status"]))
        #expect(!matches("git status $(id)", ["git status"]))
        #expect(!matches("git status > out", ["git status"]))
        #expect(!matches("git -c core.pager=evil status", ["git status"]))
        #expect(!matches("git log --output=/tmp/x", ["git log"]))
        #expect(!matches("cd /tmp && pwd", ["git status"]), "ride-alongs alone are not approved by a rule")
        #expect(!matches("cd /elsewhere && scripts/x.sh", ["scripts/x.sh"]), "a relative program never matches a prefix")
        #expect(!matches("git status", []))
    }

    // MARK: Through PermissionManager

    private func manager() throws -> (PermissionManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1102-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        return (PermissionManager(paths: paths), root)
    }

    @Test("a saved prefix rule approves attended calls, never unattended ones")
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
        #expect(!permissions.isAllowed(toolName: "run_command", details: "git push", workspace: nil))
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
