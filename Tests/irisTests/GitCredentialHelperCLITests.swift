import Foundation
import Testing
@testable import IrisKit

/// `iris --git-credential-helper` (GitHub git identity): a git credential helper invoked for
/// `get` by git's own protocol over stdin, never argv. Hands out the `iris.github` token only for
/// an exactly-matched allowed `owner/name` over https; everything else gets nothing, so git falls
/// through rather than a wrong credential ever being offered.
@Suite("git credential helper for the GitHub account (git identity)")
struct GitCredentialHelperCLITests {
    // MARK: parseFields

    @Test("parses key=value lines, ignoring a trailing blank line")
    func parsesFields() {
        let fields = GitCredentialHelperCLI.parseFields("protocol=https\nhost=github.com\npath=sackheads/iris.git\n\n")
        #expect(fields["protocol"] == "https")
        #expect(fields["host"] == "github.com")
        #expect(fields["path"] == "sackheads/iris.git")
    }

    @Test("a value may itself contain '=' and is kept whole")
    func valueWithEquals() {
        let fields = GitCredentialHelperCLI.parseFields("url=https://github.com/x?y=1\n")
        #expect(fields["url"] == "https://github.com/x?y=1")
    }

    // MARK: repoFromFields -- the must-pin boundary

    @Test("a plain https github.com path resolves to owner/name")
    func plainPath() {
        let fields = ["protocol": "https", "host": "github.com", "path": "sackheads/iris.git"]
        #expect(GitCredentialHelperCLI.repoFromFields(fields) == "sackheads/iris")
    }

    @Test("a leading slash and a missing .git suffix are both handled")
    func pathVariants() {
        #expect(GitCredentialHelperCLI.repoFromFields(["protocol": "https", "host": "github.com", "path": "/sackheads/iris.git"]) == "sackheads/iris")
        #expect(GitCredentialHelperCLI.repoFromFields(["protocol": "https", "host": "github.com", "path": "sackheads/iris"]) == "sackheads/iris")
    }

    @Test("host is matched case-insensitively, but exactly -- no lookalike", arguments: [
        "github.com.evil.com", "evil-github.com", "github.co", "github.com:443", "notgithub.com",
        "github.com evil.com", "github.com\u{0}evil.com",
    ])
    func lookalikeHostsRefused(_ host: String) {
        #expect(GitCredentialHelperCLI.repoFromFields(["protocol": "https", "host": host, "path": "sackheads/iris.git"]) == nil)
    }

    @Test("GitHub.Com matches case-insensitively")
    func hostCaseInsensitive() {
        #expect(GitCredentialHelperCLI.repoFromFields(["protocol": "https", "host": "GitHub.Com", "path": "sackheads/iris.git"]) == "sackheads/iris")
    }

    @Test("a non-https protocol is refused even against the right host", arguments: ["http", "ssh", "git", ""])
    func nonHTTPSRefused(_ proto: String) {
        #expect(GitCredentialHelperCLI.repoFromFields(["protocol": proto, "host": "github.com", "path": "sackheads/iris.git"]) == nil)
    }

    @Test("a lookalike or malformed path is refused", arguments: [
        "sackheads/iris/../../admin", "sackheads/iris?x=1", "sackheads/iris#f", "sackheads",
        "/", "sackheads/", "sackheads/iris/extra", "sackheads/iris.git@evil", "a b/c",
        "sackheads/iris.git/../etc/passwd",
    ])
    func lookalikePathsRefused(_ path: String) {
        #expect(GitCredentialHelperCLI.repoFromFields(["protocol": "https", "host": "github.com", "path": path]) == nil)
    }

    @Test("a missing protocol, host or path refuses, not crashes")
    func missingFieldsRefused() {
        #expect(GitCredentialHelperCLI.repoFromFields([:]) == nil)
        #expect(GitCredentialHelperCLI.repoFromFields(["protocol": "https"]) == nil)
        #expect(GitCredentialHelperCLI.repoFromFields(["protocol": "https", "host": "github.com"]) == nil)
    }

    // MARK: respond -- the end-to-end decision

    @Test("responds with the configured login's credential for an allowed repo")
    func respondsForAllowedRepo() {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        keychain.replaceSecrets(["token": "ghp_realtoken123"], service: KeychainManager.githubService)
        let fields = ["protocol": "https", "host": "github.com", "path": "sackheads/iris.git"]
        let output = GitCredentialHelperCLI.respond(fields: fields, keychain: keychain, login: "acme-bot", isRepoAllowed: { $0 == "sackheads/iris" })
        #expect(output == "username=acme-bot\npassword=ghp_realtoken123\n")
    }

    @Test("responds with nothing for a repo not on the allowlist, even with a valid token configured")
    func respondsEmptyForDisallowedRepo() {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        keychain.replaceSecrets(["token": "ghp_realtoken123"], service: KeychainManager.githubService)
        let fields = ["protocol": "https", "host": "github.com", "path": "evil/repo.git"]
        let output = GitCredentialHelperCLI.respond(fields: fields, keychain: keychain, login: "acme-bot", isRepoAllowed: { $0 == "sackheads/iris" })
        #expect(output.isEmpty)
    }

    @Test("responds with nothing when no token is configured, even for an allowed repo")
    func respondsEmptyWithNoToken() {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        let fields = ["protocol": "https", "host": "github.com", "path": "sackheads/iris.git"]
        let output = GitCredentialHelperCLI.respond(fields: fields, keychain: keychain, login: "acme-bot", isRepoAllowed: { $0 == "sackheads/iris" })
        #expect(output.isEmpty)
    }

    @Test("responds with nothing for a lookalike host even if the allowlist predicate would say yes")
    func respondsEmptyForLookalikeHostRegardlessOfAllowlist() {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        keychain.replaceSecrets(["token": "ghp_realtoken123"], service: KeychainManager.githubService)
        let fields = ["protocol": "https", "host": "github.com.evil.com", "path": "sackheads/iris.git"]
        let output = GitCredentialHelperCLI.respond(fields: fields, keychain: keychain, login: "acme-bot", isRepoAllowed: { _ in true })
        #expect(output.isEmpty)
    }

    @Test("responds with nothing when no login is set, or one that is not a valid login, even with a token and an allowed repo",
          arguments: [nil, "", "bad name", "x\npassword=evil", "-lead"] as [String?])
    func respondsEmptyWithoutAValidLogin(_ login: String?) {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        keychain.replaceSecrets(["token": "ghp_realtoken123"], service: KeychainManager.githubService)
        let fields = ["protocol": "https", "host": "github.com", "path": "sackheads/iris.git"]
        let output = GitCredentialHelperCLI.respond(fields: fields, keychain: keychain, login: login, isRepoAllowed: { _ in true })
        #expect(output.isEmpty)
    }

    // MARK: argv handling

    @Test("only 'get' is handled; 'store', 'erase', and anything else are no-ops", arguments: ["store", "erase", "", "GET", "list"])
    func onlyGetIsHandled(_ op: String) {
        #expect(!GitCredentialHelperCLI.isGetOperation(op))
    }

    @Test("'get' is the one handled operation")
    func getIsHandled() {
        #expect(GitCredentialHelperCLI.isGetOperation("get"))
    }
}
