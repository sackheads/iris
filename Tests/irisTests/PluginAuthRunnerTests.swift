import Foundation
import Testing
import os
@testable import iris

@Suite("Plugin Auth Runner Tests")
struct PluginAuthRunnerTests {
    let allow: PluginAuthRunner.Approver = { _ in true }

    func auth(check: String) -> IPFManifest.AuthDeclaration {
        var a = try! YAMLAuthHelper.make(kind: "external")
        a.checkCommand = check
        return a
    }

    @Test("exit 0 means signed in")
    func signedIn() async {
        let status = await PluginAuthRunner.check(auth(check: "true"), config: [:], approve: allow)
        #expect(status.signedIn)
    }

    @Test("non-zero exit means signed out")
    func signedOut() async {
        let status = await PluginAuthRunner.check(auth(check: "false"), config: [:], approve: allow)
        #expect(!status.signedIn)
    }

    @Test("config refs expand in the command as shell-quoted words")
    func configExpansion() async {
        let status = await PluginAuthRunner.check(
            auth(check: "test ${config:PROFILE} = 'my work'"), config: ["PROFILE": "my work"], approve: allow)
        #expect(status.signedIn)
    }

    @Test("config values cannot inject shell commands")
    func configInjection() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-auth-inject-\(UUID().uuidString)")
        let payload = "x; touch '\(marker.path)'; echo `touch '\(marker.path)'`"
        let status = await PluginAuthRunner.check(
            auth(check: "test ${config:PROFILE} = \(PluginAuthRunner.shellQuoted(payload))"),
            config: ["PROFILE": payload], approve: allow)
        #expect(status.signedIn)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("keychain refs are never resolved in auth commands")
    func keychainRefRejected() async {
        let status = await PluginAuthRunner.check(auth(check: "echo ${keychain:TOKEN}"), config: [:], approve: allow)
        #expect(!status.signedIn)
        #expect(status.output.contains("unresolvable"))
    }

    @Test("denied approval does not run the check command")
    func checkDenied() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-auth-denied-\(UUID().uuidString)")
        let status = await PluginAuthRunner.check(
            auth(check: "touch '\(marker.path)'"), config: [:], approve: { _ in false })
        #expect(!status.signedIn)
        #expect(status.output.contains("not approved"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("denied approval does not run the setup command")
    func setupDenied() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-auth-setup-denied-\(UUID().uuidString)")
        var a = try YAMLAuthHelper.make(kind: "external")
        a.setupCommand = "touch '\(marker.path)'"
        let output = await PluginAuthRunner.runSetup(a, config: [:], approve: { _ in false })
        #expect(output.contains("not approved"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("approver receives the expanded command")
    func approverSeesExpandedCommand() async {
        let seen = OSAllocatedUnfairLock(initialState: "")
        _ = await PluginAuthRunner.check(
            auth(check: "nlm status --profile ${config:PROFILE}"), config: ["PROFILE": "work"],
            approve: { cmd in seen.withLock { $0 = cmd }; return false })
        #expect(seen.withLock { $0 } == "nlm status --profile 'work'")
    }

    @Test("large output does not deadlock the check")
    func largeOutput() async {
        let start = ContinuousClock.now
        let status = await PluginAuthRunner.check(
            auth(check: "head -c 200000 /dev/zero | tr '\\0' 'x'; exit 0"), config: [:], approve: allow)
        #expect(status.signedIn)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test("missing check command reports signed out with explanation")
    func missingCommand() async {
        var a = auth(check: "true")
        a.checkCommand = nil
        let status = await PluginAuthRunner.check(a, config: [:], approve: allow)
        #expect(!status.signedIn)
        #expect(status.output.contains("check_command"))
    }

    @Test("check command spawns with the login-shell PATH applied")
    func checkCommandLoginPath() async {
        // #228: the bare GUI environment lacks pyenv/nvm/Homebrew shims, so a check_command
        // against one of those CLIs would exit 127. The spawned PATH must begin with the login dirs.
        let status = await PluginAuthRunner.check(auth(check: "printf '%s' \"$PATH\""), config: [:], approve: allow)
        #expect(status.signedIn)
        let firstLogin = BinaryResolver.defaultSearchDirs().first!
        #expect(status.output.split(separator: ":").first.map(String.init) == firstLogin)
    }

    // MARK: The settings pane (#336)

    /// An isolated allowlist, so the outcome depends only on the rule a test writes (invariant 7).
    private func permissions() -> (PermissionManager, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-plugin-auth-\(UUID().uuidString)", isDirectory: true)
        return (PermissionManager(paths: IrisPaths(root: home)), home)
    }

    private func marker() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("iris-auth-open-\(UUID().uuidString)")
    }

    @Test("opening the pane runs nothing and asks nobody when no rule permits the check")
    func openRunsNothingUnallowed() async throws {
        let (perms, home) = permissions()
        defer { try? FileManager.default.removeItem(at: home) }
        let m = marker()
        let status = await PluginAuthRunner.statusOnOpen(auth(check: "touch '\(m.path)'"), config: [:],
                                                         permissions: perms)
        #expect(status == nil, "not checked: the pane offers its Check button instead of a prompt elsewhere")
        #expect(!FileManager.default.fileExists(atPath: m.path))
    }

    @Test("opening the pane refreshes a check an Always-allow rule already permits")
    func openRunsAllowlistedCheck() async throws {
        let (perms, home) = permissions()
        defer { try? FileManager.default.removeItem(at: home) }
        let m = marker()
        defer { try? FileManager.default.removeItem(at: m) }
        let command = "touch '\(m.path)'"
        perms.allowGlobally(toolName: "run_command", details: command)
        let status = await PluginAuthRunner.statusOnOpen(auth(check: command), config: [:], permissions: perms)
        #expect(status?.signedIn == true)
        #expect(FileManager.default.fileExists(atPath: m.path))
    }

    @Test("a check with hidden characters never runs on open, even with a rule for it")
    func openRefusesHiddenCharacters() async throws {
        let (perms, home) = permissions()
        defer { try? FileManager.default.removeItem(at: home) }
        let m = marker()
        let command = "true\ntouch '\(m.path)'"
        perms.allowGlobally(toolName: "run_command", details: command)
        let status = await PluginAuthRunner.statusOnOpen(auth(check: command), config: [:], permissions: perms)
        #expect(status == nil)
        #expect(!FileManager.default.fileExists(atPath: m.path))
    }

    @Test("the command the pane shows is exactly the command the click runs")
    func shownIsRun() async throws {
        var a = auth(check: "nlm status --profile ${config:PROFILE}")
        a.setupCommand = "nlm login --profile ${config:PROFILE}"
        let config = ["PROFILE": "my work; rm -rf x"]
        let shown = PluginAuthRunner.displayCommands(a, config: config)
        let ran = OSAllocatedUnfairLock(initialState: [String]())
        let record: PluginAuthRunner.Approver = { cmd in ran.withLock { $0.append(cmd) }; return false }
        _ = await PluginAuthRunner.check(a, config: config, approve: record)
        _ = await PluginAuthRunner.runSetup(a, config: config, approve: record)
        #expect(ran.withLock { $0 } == [shown.check, shown.setup].compactMap { $0 })
        #expect(shown.check == "nlm status --profile 'my work; rm -rf x'")
    }

    @Test("an unresolvable reference shows no command, so no button can run one")
    func unresolvableShowsNothing() {
        let shown = PluginAuthRunner.displayCommands(auth(check: "echo ${keychain:TOKEN}"), config: [:])
        #expect(shown.check == nil)
    }

    // MARK: "Always allow this command" checkbox (#338)

    @Test("checked at Check writes a rule that auto-checks the next open")
    func alwaysAllowCheckedWritesRuleAndAutoChecksNextOpen() async throws {
        let (perms, home) = permissions()
        defer { try? FileManager.default.removeItem(at: home) }
        let m = marker()
        defer { try? FileManager.default.removeItem(at: m) }
        let command = "touch '\(m.path)'"

        // Not yet allowed: the pane would show "Not checked" on open.
        let before = await PluginAuthRunner.statusOnOpen(auth(check: command), config: [:], permissions: perms)
        #expect(before == nil)

        // The checkbox was on when the user clicked Check.
        let wrote = PluginAuthRunner.applyAlwaysAllow(command: command, requested: true, permissions: perms)
        #expect(wrote)

        // Next time the pane opens, the rule lets the check run unasked.
        let after = await PluginAuthRunner.statusOnOpen(auth(check: command), config: [:], permissions: perms)
        #expect(after?.signedIn == true)
    }

    @Test("unchecked at Check writes no rule")
    func alwaysAllowUncheckedWritesNoRule() {
        let (perms, home) = permissions()
        defer { try? FileManager.default.removeItem(at: home) }
        let command = "true"
        let wrote = PluginAuthRunner.applyAlwaysAllow(command: command, requested: false, permissions: perms)
        #expect(!wrote)
        #expect(!PluginAuthRunner.isAlwaysAllowed(command, permissions: perms))
    }

    @Test("a command with hidden characters cannot be allowed even if requested")
    func alwaysAllowRefusesHiddenCharacters() {
        let (perms, home) = permissions()
        defer { try? FileManager.default.removeItem(at: home) }
        let command = "true\ntouch '/tmp/should-not-run'"
        let wrote = PluginAuthRunner.applyAlwaysAllow(command: command, requested: true, permissions: perms)
        #expect(!wrote)
        #expect(!PluginAuthRunner.isAlwaysAllowed(command, permissions: perms))
    }

    @Test("a nil command (nothing declared, or unresolvable) cannot be allowed")
    func alwaysAllowRefusesNilCommand() {
        let (perms, home) = permissions()
        defer { try? FileManager.default.removeItem(at: home) }
        let wrote = PluginAuthRunner.applyAlwaysAllow(command: nil, requested: true, permissions: perms)
        #expect(!wrote)
    }

    @Test("setup_command has no always-allow path: applying it to the setup command's text has no effect")
    func setupCommandCannotBeAlwaysAllowed() async {
        // There is no checkbox beside Sign In in the view, and PluginAuthRunner exposes no
        // "always allow setup" entry point — `applyAlwaysAllow` is only ever called by the pane
        // with the *check* command's text. This pins that `runSetup` itself still asks every
        // time regardless of any rule for that same command string, so a future caller cannot
        // smuggle setup_command through the check-only checkbox's plumbing.
        let (perms, home) = permissions()
        defer { try? FileManager.default.removeItem(at: home) }
        var a = auth(check: "true")
        a.setupCommand = "true"
        perms.allowGlobally(toolName: "run_command", details: "true")
        // Even with a global rule for the identical command text, runSetup still requires an
        // explicit approve — there is no "statusOnOpen" equivalent for setup.
        let output = await PluginAuthRunner.runSetup(a, config: [:], approve: { _ in false })
        #expect(output.contains("not approved"))
    }
}

/// Test-only helper: AuthDeclaration has no memberwise init exposed for `kind` alone.
enum YAMLAuthHelper {
    static func make(kind: String) throws -> IPFManifest.AuthDeclaration {
        let m = try IPFManifest.parse(
            markdown: "---\nipf: \"1.0\"\nid: t\nname: T\nversion: 1.0.0\nauth:\n  - kind: \(kind)\n---\n",
            directoryName: "t")
        return m.auth![0]
    }
}
