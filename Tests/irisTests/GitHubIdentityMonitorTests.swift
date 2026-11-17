import Foundation
import Testing
@testable import IrisKit

/// #1184: the `github_*` tools are offered only while `GET /user` names the configured login. Three
/// outcomes stay distinct: a match offers them, a mismatch and an unverifiable answer both keep them
/// off, and only a mismatch is ever reported as one.
@Suite("GitHub identity gate (#1184)", .timeLimit(.minutes(1)))
struct GitHubIdentityMonitorTests {
    private static let token = "ghp_TestToken1234567890abcdef"

    private struct Rig {
        let config: ConfigManager
        let keychain: KeychainManager
        func teardown() {}
    }

    /// A manager configured at launch (token, one repo, login acme-bot) over its own store and keychain.
    private func rig(login: String? = "acme-bot", token: Bool = true) -> Rig {
        let name = "iris-1184g-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        if token { keychain.replaceSecrets(["token": Self.token], service: KeychainManager.githubService) }
        let seed = ConfigManager(store: store, guardedSecrets: keychain)
        seed.setGuardedBlob(.githubAllowedRepos, "[\"sackheads/iris\"]")
        if let login { seed.setGuardedBlob(.githubLogin, GitHubProxyClient.loginBlob(login)) }
        return Rig(config: ConfigManager(store: store, guardedSecrets: keychain), keychain: keychain)
    }

    private final class Counting: GitHubTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        let reply: @Sendable () throws -> (Data, Int)
        init(_ reply: @escaping @Sendable () throws -> (Data, Int)) { self.reply = reply }
        var calls: Int { lock.withLock { _calls } }
        func send(_ request: URLRequest, bearer: String) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { _calls += 1 }
            let (data, status) = try reply()
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func user(_ login: String, _ status: Int = 200) -> Counting {
        Counting { (try JSONSerialization.data(withJSONObject: ["login": login]), status) }
    }

    @Test("configured at launch is not enough: the tools are off until GET /user says the login")
    func offUntilChecked() async {
        let r = rig()
        #expect(r.config.githubConfiguredAtLaunch)
        #expect(!r.config.githubToolsConfigured && r.config.githubIdentity == nil)
        let result = await GitHubIdentityMonitor.verify(config: r.config, keychain: r.keychain, transport: user("Acme-Bot"))
        #expect(result == .match && r.config.githubIdentity == .match)
        #expect(r.config.githubToolsConfigured)
    }

    @Test("a token for another account is a mismatch that names it: the tools stay off")
    func mismatchIsOff() async {
        let r = rig()
        await GitHubIdentityMonitor.verify(config: r.config, keychain: r.keychain, transport: user("someone-else"))
        #expect(r.config.githubIdentity == .mismatch(actual: "someone-else"))
        #expect(!r.config.githubToolsConfigured)
    }

    @Test("a check that could not be made is unverified, never a mismatch, and the tools stay off",
          arguments: [503, 401, 500] as [Int])
    func unverifiedIsOffAndNotAMismatch(_ status: Int) async {
        let r = rig()
        await GitHubIdentityMonitor.verify(config: r.config, keychain: r.keychain, transport: user("acme-bot", status))
        guard case .unverified = r.config.githubIdentity else { Issue.record("expected unverified, got \(String(describing: r.config.githubIdentity))"); return }
        #expect(!r.config.githubToolsConfigured)
    }

    @Test("a network error is unverified too")
    func networkErrorIsUnverified() async {
        let r = rig()
        await GitHubIdentityMonitor.verify(config: r.config, keychain: r.keychain,
                                           transport: Counting { throw URLError(.notConnectedToInternet) })
        guard case .unverified = r.config.githubIdentity else { Issue.record("expected unverified"); return }
        #expect(!r.config.githubToolsConfigured)
    }

    @Test("a change to the token or login clears a match at once, and an answer for the old pair is dropped")
    func changeInvalidates() async {
        let r = rig()
        await GitHubIdentityMonitor.verify(config: r.config, keychain: r.keychain, transport: user("acme-bot"))
        #expect(r.config.githubToolsConfigured)
        r.config.invalidateGitHubIdentity()
        #expect(!r.config.githubToolsConfigured && r.config.githubIdentity == nil)

        let generation = r.config.beginGitHubIdentityCheck()
        r.config.invalidateGitHubIdentity()
        r.config.finishGitHubIdentityCheck(try! #require(generation), .match)
        #expect(!r.config.githubToolsConfigured, "a stale match must not turn the tools on")
    }

    @Test("nothing is asked without a login or a token")
    func nothingToAsk() async {
        let noLogin = rig(login: nil)
        let t1 = user("acme-bot")
        #expect(await GitHubIdentityMonitor.verify(config: noLogin.config, keychain: noLogin.keychain, transport: t1) == nil)
        #expect(t1.calls == 0)
        let noToken = rig(token: false)
        let t2 = user("acme-bot")
        _ = await GitHubIdentityMonitor.verify(config: noToken.config, keychain: noToken.keychain, transport: t2)
        #expect(t2.calls == 0 && !noToken.config.githubToolsConfigured)
    }

    @Test("a hung GET /user does not block the caller, and the tools stay off until it answers")
    func hungCheckDoesNotBlock() async throws {
        let r = rig()
        let gate = DispatchSemaphore(value: 0)
        let hung = Counting {
            gate.wait()
            return (try JSONSerialization.data(withJSONObject: ["login": "acme-bot"]), 200)
        }
        let task = try #require(GitHubIdentityMonitor.kickIfNeeded(config: r.config, keychain: r.keychain, transport: hung))
        // kickIfNeeded returned without waiting for the request: still off, still unchecked.
        #expect(!r.config.githubToolsConfigured && r.config.githubIdentity == nil)
        gate.signal()
        try await value(of: task, within: 20)
        #expect(r.config.githubToolsConfigured)
    }

    @Test("it only asks when configured at launch, and not again after a match or a mismatch")
    func kickOnlyWhenNeeded() async throws {
        let unconfigured = rig(login: nil)
        #expect(GitHubIdentityMonitor.kickIfNeeded(config: unconfigured.config, keychain: unconfigured.keychain, transport: user("x")) == nil)

        let r = rig()
        let t = user("acme-bot")
        let first = try #require(GitHubIdentityMonitor.kickIfNeeded(config: r.config, keychain: r.keychain, transport: t))
        try await value(of: first, within: 20)
        #expect(GitHubIdentityMonitor.kickIfNeeded(config: r.config, keychain: r.keychain, transport: t) == nil, "already matched")
        #expect(t.calls == 1)

        let m = rig()
        let wrong = user("someone-else")
        try await value(of: try #require(GitHubIdentityMonitor.kickIfNeeded(config: m.config, keychain: m.keychain, transport: wrong)), within: 20)
        #expect(GitHubIdentityMonitor.kickIfNeeded(config: m.config, keychain: m.keychain, transport: wrong) == nil, "a mismatch waits for a change, not a retry")
    }

    @Test("an unverified answer is retried, but not more often than the interval")
    func retryIsThrottled() async throws {
        let r = rig()
        let down = Counting { throw URLError(.timedOut) }
        let first = try #require(GitHubIdentityMonitor.kickIfNeeded(config: r.config, keychain: r.keychain, transport: down))
        try await value(of: first, within: 20)
        #expect(down.calls == 1)
        // A turn right after: throttled, so the task starts but asks nothing.
        let second = try #require(GitHubIdentityMonitor.kickIfNeeded(config: r.config, keychain: r.keychain, transport: down))
        try await value(of: second, within: 20)
        #expect(down.calls == 1, "inside the retry interval nothing is asked")
        // Past the interval a begin is allowed again.
        #expect(r.config.beginGitHubIdentityCheck(minInterval: GitHubIdentityMonitor.retryInterval,
                                                  now: ProcessInfo.processInfo.systemUptime + GitHubIdentityMonitor.retryInterval + 1) != nil)
    }
}

/// #1190: a check that begins between the invalidate and the write of a new token or login read the old
/// pair, but carried the then-current generation, so its answer was recorded as the new pair's.
@Suite("GitHub identity gate: the write window (#1190)", .timeLimit(.minutes(1)))
struct GitHubIdentityWriteWindowTests {
    private func configured() -> (ConfigManager, KeychainManager) {
        let name = "iris-1190-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        keychain.replaceSecrets(["token": "ghp_OldToken1234567890abcdef"], service: KeychainManager.githubService)
        let seed = ConfigManager(store: store, guardedSecrets: keychain)
        seed.setGuardedBlob(.githubAllowedRepos, "[\"sackheads/iris\"]")
        seed.setGuardedBlob(.githubLogin, GitHubProxyClient.loginBlob("acme-bot"))
        return (ConfigManager(store: store, guardedSecrets: keychain), keychain)
    }

    private final class Held: GitHubTransport, @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        /// Sync, so the blocking wait is not in an async context.
        private func holdUntilReleased() { release.wait() }
        func send(_ request: URLRequest, bearer: String) async throws -> (Data, HTTPURLResponse) {
            started.signal()
            holdUntilReleased()
            return (try JSONSerialization.data(withJSONObject: ["login": "acme-bot"]),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("a check begun inside the write is dropped when the write ends: it must not record a match")
    func checkInsideTheWriteIsDropped() async throws {
        let (config, keychain) = configured()
        let held = Held()
        var task: Task<Void, Never>?
        config.changingGitHubIdentityInputs {
            // A turn starts here: after the first drop, before the new value is stored.
            task = GitHubIdentityMonitor.kickIfNeeded(config: config, keychain: keychain, transport: held)
            held.started.wait()
            keychain.replaceSecrets(["token": "ghp_NewToken1234567890abcdef"], service: KeychainManager.githubService)
        }
        held.release.signal()
        try await value(of: try #require(task), within: 20)
        #expect(config.githubIdentity == nil, "the answer was for the old token")
        #expect(!config.githubToolsConfigured)
    }

    @Test("the match standing before a write is gone while the write runs")
    func matchDroppedBeforeTheWrite() async {
        let (config, keychain) = configured()
        let id = config.beginGitHubIdentityCheck()
        config.finishGitHubIdentityCheck(try! #require(id), .match)
        #expect(config.githubToolsConfigured)
        config.changingGitHubIdentityInputs {
            #expect(config.githubIdentity == nil && !config.githubToolsConfigured)
        }
        _ = keychain
    }

    @Test("a check begun after the write read the new pair and stands")
    func checkAfterTheWriteStands() async throws {
        let (config, keychain) = configured()
        config.changingGitHubIdentityInputs {
            keychain.replaceSecrets(["token": "ghp_NewToken1234567890abcdef"], service: KeychainManager.githubService)
        }
        let result = await GitHubIdentityMonitor.verify(config: config, keychain: keychain, transport: {
            struct Ok: GitHubTransport {
                func send(_ request: URLRequest, bearer: String) async throws -> (Data, HTTPURLResponse) {
                    (try JSONSerialization.data(withJSONObject: ["login": "acme-bot"]),
                     HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            }
            return Ok()
        }())
        #expect(result == .match && config.githubIdentity == .match)
    }
}
