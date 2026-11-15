import Foundation
import Testing
@testable import IrisKit

@Suite("GitHubProxyClient: Keychain token lookup (#966 Task 1)")
struct GitHubProxyClientTests {
    @Test("hasToken is false over an empty store, true after a token is written")
    func hasTokenReadsTheGithubService() {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        #expect(!GitHubProxyClient.hasToken(keychain: keychain))
        #expect(GitHubProxyClient.token(keychain: keychain) == nil)

        keychain.replaceSecrets(["token": "ghp_test123"], service: KeychainManager.githubService)

        #expect(GitHubProxyClient.hasToken(keychain: keychain))
        #expect(GitHubProxyClient.token(keychain: keychain) == "ghp_test123")
    }

    @Test("an empty or whitespace-only stored token counts as absent (dev-2's finding)")
    func emptyOrWhitespaceTokenIsAbsent() {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        keychain.replaceSecrets(["token": ""], service: KeychainManager.githubService)
        #expect(!GitHubProxyClient.hasToken(keychain: keychain))
        #expect(GitHubProxyClient.token(keychain: keychain) == nil)

        keychain.replaceSecrets(["token": "  \n"], service: KeychainManager.githubService)
        #expect(!GitHubProxyClient.hasToken(keychain: keychain))
        #expect(GitHubProxyClient.token(keychain: keychain) == nil)
    }

    @Test("ConfigManager caches the presence check once at init, not per read (#966 Task 1, dev-3's finding)")
    func configManagerCachesPresence() {
        let name = "iris-966-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }

        let withoutToken = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        #expect(!ConfigManager(store: store, guardedSecrets: withoutToken).hasGitHubToken)

        let withToken = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        withToken.replaceSecrets(["token": "ghp_cached"], service: KeychainManager.githubService)
        #expect(ConfigManager(store: store, guardedSecrets: withToken).hasGitHubToken)
    }

    @Test("the cached flag is fixed at construction, not computed per access (dev-2's finding)")
    func cachedFlagDoesNotLiveRefresh() {
        let name = "iris-966-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        let config = ConfigManager(store: store, guardedSecrets: keychain)
        #expect(!config.hasGitHubToken)

        // A write after construction must not retroactively flip an already-built manager's flag
        // -- that would mean the value is computed per access, not cached once at launch, and
        // #966's headless setter (a separate process) relies on exactly that fixed-ness.
        keychain.replaceSecrets(["token": "ghp_written_later"], service: KeychainManager.githubService)
        #expect(!config.hasGitHubToken)
    }
}

/// A transport that never touches the network: it records what the client would have sent and
/// plays back queued responses (or throws).
private final class StubTransport: GitHubTransport, @unchecked Sendable {
    struct Sent { let request: URLRequest; let bearer: String }
    private let lock = NSLock()
    private var _sent: [Sent] = []
    private var queue: [Result<(Data, Int), Error>]

    init(_ responses: [Result<(Data, Int), Error>]) { queue = responses }
    var sent: [Sent] { lock.withLock { _sent } }

    func send(_ request: URLRequest, bearer: String) async throws -> (Data, HTTPURLResponse) {
        let next: Result<(Data, Int), Error> = lock.withLock {
            _sent.append(Sent(request: request, bearer: bearer))
            return queue.isEmpty ? .failure(URLError(.cannotConnectToHost)) : queue.removeFirst()
        }
        let (data, status) = try next.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

@Suite("GitHubProxyClient: create-PR and comment (#966 Task 3)")
struct GitHubProxyClientRESTTests {
    static let token = "ghp_SuperSecretToken1234567890"

    private func client(_ responses: [Result<(Data, Int), Error>], allowed: Set<String> = ["sackheads/iris"],
                        token: String? = GitHubProxyClientRESTTests.token) -> (GitHubProxyClient, StubTransport) {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        if let token { keychain.replaceSecrets(["token": token], service: KeychainManager.githubService) }
        let stub = StubTransport(responses)
        return (GitHubProxyClient(keychain: keychain, isRepoAllowed: { allowed.contains($0) }, transport: stub), stub)
    }

    private func json(_ object: [String: Any], _ status: Int = 201) -> Result<(Data, Int), Error> {
        .success((try! JSONSerialization.data(withJSONObject: object), status))
    }

    private func body(_ sent: StubTransport.Sent) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: sent.request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    @Test("createPR POSTs /pulls as iris-main with the token as bearer, and reports the PR url")
    func createPRSendsTheRightRequest() async {
        let (c, stub) = client([json(["number": 12, "html_url": "https://github.com/sackheads/iris/pull/12"])])
        let result = await c.createPR(repo: "sackheads/iris", head: "docs/x", base: "main",
                                      title: "Add x", body: "Body", draft: true)
        #expect(stub.sent.count == 1)
        let sent = stub.sent[0]
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.absoluteString == "https://api.github.com/repos/sackheads/iris/pulls")
        #expect(sent.bearer == Self.token)
        #expect(body(sent)["head"] as? String == "docs/x")
        #expect(body(sent)["base"] as? String == "main")
        #expect(body(sent)["title"] as? String == "Add x")
        #expect(body(sent)["body"] as? String == "Body")
        #expect(body(sent)["draft"] as? Bool == true)
        #expect(result.contains("#12"))
        #expect(result.contains("https://github.com/sackheads/iris/pull/12"))
        #expect(!result.contains(Self.token))
    }

    @Test("comment POSTs /issues/{n}/comments and reports the comment url")
    func commentSendsTheRightRequest() async {
        let (c, stub) = client([json(["html_url": "https://github.com/sackheads/iris/pull/7#issuecomment-1"])])
        let result = await c.comment(repo: "sackheads/iris", pr: 7, body: "lgtm")
        let sent = stub.sent[0]
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.absoluteString == "https://api.github.com/repos/sackheads/iris/issues/7/comments")
        #expect(sent.bearer == Self.token)
        #expect(body(sent)["body"] as? String == "lgtm")
        #expect(result.contains("https://github.com/sackheads/iris/pull/7#issuecomment-1"))
    }

    @Test("a repo not on the allowlist is refused before any request, and the transport is never called",
          arguments: ["evil/repo", "", "sackheads/iris-other", "SACKHEADS/IRIS"])
    func unlistedRepoNeverReachesTheNetwork(_ repo: String) async {
        let (c, stub) = client([json(["number": 1, "html_url": "https://github.com/x/y/pull/1"])])
        let created = await c.createPR(repo: repo, head: "h", base: "main", title: "t", body: "b", draft: false)
        let commented = await c.comment(repo: repo, pr: 1, body: "b")
        #expect(stub.sent.isEmpty)
        #expect(created.lowercased().contains("not allowed"))
        #expect(commented.lowercased().contains("not allowed"))
    }

    @Test("an empty allowlist refuses everything (fail-closed default)")
    func emptyAllowlistRefuses() async {
        let (c, stub) = client([], allowed: [])
        _ = await c.comment(repo: "sackheads/iris", pr: 1, body: "b")
        #expect(stub.sent.isEmpty)
    }

    @Test("with no token configured nothing is sent")
    func noTokenNoRequest() async {
        let (c, stub) = client([json(["html_url": "https://github.com/a/b/pull/1"])], token: nil)
        let result = await c.comment(repo: "sackheads/iris", pr: 1, body: "b")
        #expect(stub.sent.isEmpty)
        #expect(result.lowercased().contains("token"))
    }

    @Test("a repo that is listed but not owner/name shaped is refused, so no model text reaches a URL path",
          arguments: ["sackheads/iris/../../admin", "sackheads/iris?x=1", "sackheads/iris#f", "sackheads", "/iris", "a b/c"])
    func malformedRepoNeverBuildsAURL(_ repo: String) async {
        let (c, stub) = client([json(["html_url": "https://github.com/a/b/pull/1"])], allowed: [repo])
        _ = await c.comment(repo: repo, pr: 1, body: "b")
        _ = await c.createPR(repo: repo, head: "h", base: "main", title: "t", body: "b", draft: false)
        #expect(stub.sent.isEmpty)
    }

    @Test("a non-positive pr number is refused without a request", arguments: [0, -1])
    func nonPositivePRRefused(_ pr: Int) async {
        let (c, stub) = client([])
        _ = await c.comment(repo: "sackheads/iris", pr: pr, body: "b")
        #expect(stub.sent.isEmpty)
    }

    @Test("a transport error that echoes the token returns a string without it (C2)")
    func transportErrorIsScrubbed() async {
        struct Echo: Error, LocalizedError { let text: String; var errorDescription: String? { text } }
        let (c, _) = client([.failure(Echo(text: "connection failed with Authorization: Bearer \(Self.token)"))])
        let result = await c.comment(repo: "sackheads/iris", pr: 1, body: "b")
        #expect(!result.contains(Self.token))
        #expect(result.contains("[redacted]"))
    }

    @Test("an HTTP error whose body echoes the token returns a string without it, keeping the status")
    func httpErrorBodyIsScrubbed() async {
        let (c, _) = client([json(["message": "Bad credentials for \(Self.token)"], 401)])
        let created = await c.createPR(repo: "sackheads/iris", head: "h", base: "main", title: "t", body: "b", draft: false)
        #expect(!created.contains(Self.token))
        #expect(created.contains("401"))
    }

    @Test("a success body that echoes the token in its url is scrubbed too")
    func successBodyIsScrubbed() async {
        let (c, _) = client([json(["number": 3, "html_url": "https://github.com/sackheads/iris/pull/3?t=\(Self.token)"])])
        let result = await c.createPR(repo: "sackheads/iris", head: "h", base: "main", title: "t", body: "b", draft: false)
        #expect(!result.contains(Self.token))
    }

    @Test("a non-github url in the response is not echoed to the model")
    func foreignURLIsNotEchoed() async {
        let (c, _) = client([json(["number": 3, "html_url": "https://evil.example/phish"])])
        let result = await c.createPR(repo: "sackheads/iris", head: "h", base: "main", title: "t", body: "b", draft: false)
        #expect(!result.contains("evil.example"))
    }

    @Test("an unparseable response body still gives a result with the status, no crash")
    func garbageBodyIsHandled() async {
        let (c, _) = client([.success((Data("<html>oops</html>".utf8), 502))])
        let result = await c.comment(repo: "sackheads/iris", pr: 1, body: "b")
        #expect(result.contains("502"))
    }

    @Test("an error message from GitHub is length-capped and stripped of control characters")
    func errorMessageIsBounded() async {
        let long = String(repeating: "x", count: 5000) + "\u{0007}\nINJECT"
        let (c, _) = client([json(["message": long], 422)])
        let result = await c.comment(repo: "sackheads/iris", pr: 1, body: "b")
        #expect(result.count < 600)
        #expect(!result.contains("\u{0007}"))
    }

    @Test("the real transport never follows a redirect, so the bearer cannot be replayed to another host")
    func realTransportDoesNotFollowRedirects() {
        #expect(URLSessionGitHubTransport().session === NoRedirectSessionDelegate.session)
    }
}
