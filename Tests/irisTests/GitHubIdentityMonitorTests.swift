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

    private struct AnswersAcmeBot: GitHubTransport {
        func send(_ request: URLRequest, bearer: String) async throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: ["login": "acme-bot"]),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("the login is read after the check begins: a change completing between the two drops the answer")
    func loginIsReadAfterBegin() async {
        let (config, keychain) = configured()
        let result = await GitHubIdentityMonitor.verify(config: config, keychain: keychain, transport: AnswersAcmeBot(), loginProvider: {
            // The login is being read: a change lands now, and hands back the OLD login.
            config.changingGitHubIdentityInputs { config.setGuardedBlob(.githubLogin, GitHubProxyClient.loginBlob("new-name")) }
            return "acme-bot"
        })
        #expect(config.githubIdentity == nil, "the answer was for the old login, \(String(describing: result))")
        #expect(!config.githubToolsConfigured)
    }

    @Test("a check that finds no login ends cleanly: the next one is not blocked as still running")
    func noLoginFreesTheSlot() async {
        let (config, keychain) = configured()
        config.setGuardedBlob(.githubLogin, "")
        #expect(config.githubLogin() == nil)
        #expect(await GitHubIdentityMonitor.verify(config: config, keychain: keychain, transport: AnswersAcmeBot()) == nil)
        config.setGuardedBlob(.githubLogin, GitHubProxyClient.loginBlob("acme-bot"))
        #expect(await GitHubIdentityMonitor.verify(config: config, keychain: keychain, transport: AnswersAcmeBot()) == .match)
    }

    @Test("all four pane writers go through changingGitHubIdentityInputs, and none drops the state by hand")
    func everyWriterIsWrapped() throws {
        let url = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/GitHubSettingsModel.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("invalidateGitHubIdentity()"), "a drop-before-only call would leave the window open")
        for name in ["saveLogin", "clearLogin", "saveToken", "clearToken"] {
            let start = try #require(source.range(of: "func \(name)("), Comment(rawValue: name))
            let rest = source[start.upperBound...]
            let end = rest.range(of: "\n    @discardableResult")?.lowerBound ?? rest.endIndex
            #expect(rest[..<end].contains("changingGitHubIdentityInputs"), Comment(rawValue: "\(name) must write through the guard"))
        }
    }
}

/// #1189: overlapping checks coalesce. `beginGitHubIdentityCheck` is the guard: one check runs at a
/// time, so a burst of turns reading the gate (each calling `kickIfNeeded`) asks GitHub once.
@Suite("GitHub identity gate: overlapping checks coalesce (#1189)", .timeLimit(.minutes(1)))
struct GitHubIdentityInFlightTests {
    /// Overlapping begins are free to fire in bulk; overlapping requests each hold a thread, so fewer.
    private static let width = 64
    private static let heldWidth = 6

    private func configured() -> (ConfigManager, KeychainManager) {
        let name = "iris-1189-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        keychain.replaceSecrets(["token": "ghp_TestToken1234567890abcdef"], service: KeychainManager.githubService)
        let seed = ConfigManager(store: store, guardedSecrets: keychain)
        seed.setGuardedBlob(.githubAllowedRepos, "[\"sackheads/iris\"]")
        seed.setGuardedBlob(.githubLogin, GitHubProxyClient.loginBlob("acme-bot"))
        return (ConfigManager(store: store, guardedSecrets: keychain), keychain)
    }

    /// Counts requests and holds each one until released, so every other caller overlaps it.
    private final class Held: GitHubTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var calls: Int { lock.withLock { _calls } }
        /// Bounded, so a broken guard fails the test instead of parking every pool thread for good.
        private func hold() { _ = release.wait(timeout: .now() + 8) }
        /// Sync, so the blocking wait is not in an async context.
        func awaitStarted() { started.wait() }
        func send(_ request: URLRequest, bearer: String) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { _calls += 1 }
            started.signal()
            hold()
            return (try JSONSerialization.data(withJSONObject: ["login": "acme-bot"]),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func bump() { lock.withLock { _count += 1 } }
    }

    @Test("many threads begin at once and exactly one is let through")
    func oneBeginWins() {
        let (config, _) = configured()
        let wins = Tally()
        DispatchQueue.concurrentPerform(iterations: Self.width) { _ in
            if config.beginGitHubIdentityCheck() != nil { wins.bump() }
        }
        #expect(wins.count == 1, "\(wins.count) checks began while one was in flight")
    }

    @Test("the slot is released by finishing, abandoning or invalidating, and then the next begin is let through")
    func slotIsReleased() throws {
        let (config, _) = configured()
        let g1 = try #require(config.beginGitHubIdentityCheck())
        #expect(config.beginGitHubIdentityCheck() == nil)
        config.finishGitHubIdentityCheck(g1, .match)
        let g2 = try #require(config.beginGitHubIdentityCheck())
        #expect(config.beginGitHubIdentityCheck() == nil)
        config.abandonGitHubIdentityCheck(g2)
        let g3 = try #require(config.beginGitHubIdentityCheck())
        #expect(config.beginGitHubIdentityCheck() == nil)
        config.invalidateGitHubIdentity()
        #expect(config.beginGitHubIdentityCheck() != nil)
        _ = g3
    }

    @Test("a burst of kicks while one check is in flight sends one request, and the tools follow its answer")
    func burstOfKicksAsksOnce() async throws {
        let (config, keychain) = configured()
        let held = Held()
        let first = try #require(GitHubIdentityMonitor.kickIfNeeded(config: config, keychain: keychain, transport: held))
        held.awaitStarted()
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<Self.heldWidth {
            if let t = GitHubIdentityMonitor.kickIfNeeded(config: config, keychain: keychain, transport: held) { tasks.append(t) }
        }
        for t in tasks { try await value(of: t, within: 20) }
        #expect(held.calls == 1, "\(held.calls) requests overlapped the in-flight check")
        #expect(!config.githubToolsConfigured, "still waiting on the one request")
        held.release.signal()
        try await value(of: first, within: 20)
        #expect(held.calls == 1 && config.githubToolsConfigured)
    }

    @Test("concurrent verifies coalesce too: one asks, the rest return nothing")
    func concurrentVerifiesCoalesce() async throws {
        let (config, keychain) = configured()
        let held = Held()
        let results = await withTaskGroup(of: GitHubProxyClient.IdentityCheck?.self) { group in
            group.addTask { await GitHubIdentityMonitor.verify(config: config, keychain: keychain, transport: held) }
            // Wait for the first to reach the transport before the rest start.
            await Task.detached { held.awaitStarted() }.value
            for _ in 0..<Self.heldWidth {
                group.addTask { await GitHubIdentityMonitor.verify(config: config, keychain: keychain, transport: held) }
            }
            var others: [GitHubProxyClient.IdentityCheck?] = []
            var seen = 0
            for await result in group {
                seen += 1
                if result == nil { others.append(result) }
                if seen == Self.heldWidth { held.release.signal() }
            }
            return others
        }
        #expect(held.calls == 1, "\(held.calls) requests")
        #expect(results.count == Self.heldWidth, "every overlapping caller got nothing back")
        #expect(config.githubIdentity == .match)
    }
}
