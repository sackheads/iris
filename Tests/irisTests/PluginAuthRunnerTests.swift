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
