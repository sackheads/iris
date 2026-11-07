import Testing
import Foundation
import CFNetwork
@testable import IrisKit

/// #904: before wiring `WKWebsiteDataStore.proxyConfigurations` to the viewer, prove the test
/// harness itself decodes a real SOCKS5 CONNECT correctly — a plain `URLSession`, configured to
/// route through the proxy via `connectionProxyDictionary`, is the same client shape
/// `URLSessionConfiguration` wiring will eventually use, just without the viewer in between.
@Suite("SOCKS5 proxy test helper (#904)", .timeLimit(.minutes(1)))
struct SOCKS5ProxyTestHelperTests {
    private func proxiedSession(port: UInt16) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: Int(port),
        ]
        return URLSession(configuration: config)
    }

    @Test("a URLSession request through the proxy records the target hostname, not an IP")
    func recordsHostname() async throws {
        let proxy = try SOCKS5ProxyTestHelper()
        defer { proxy.close() }

        let session = proxiedSession(port: proxy.port)
        // The target need not exist or answer: the proxy itself closes the connection right after
        // its CONNECT reply, so the request always fails — only the recorded target matters here.
        _ = try? await session.data(from: URL(string: "http://iris-dns-probe.invalid.example/")!)

        let targets = proxy.recordedTargets
        #expect(targets.count == 1)
        #expect(targets.first?.host == "iris-dns-probe.invalid.example")
        #expect(targets.first?.port == 80)
    }

    @Test("a refusing proxy still records the target before declining it")
    func recordsEvenWhenRefusing() async throws {
        let proxy = try SOCKS5ProxyTestHelper(outcome: .refuse)
        defer { proxy.close() }

        let session = proxiedSession(port: proxy.port)
        _ = try? await session.data(from: URL(string: "http://iris-dns-refused.invalid.example/")!)

        #expect(proxy.recordedTargets.map(\.host) == ["iris-dns-refused.invalid.example"])
    }

    @Test("two sequential requests are both recorded, in order")
    func recordsMultipleRequestsInOrder() async throws {
        let proxy = try SOCKS5ProxyTestHelper()
        defer { proxy.close() }

        let session = proxiedSession(port: proxy.port)
        _ = try? await session.data(from: URL(string: "http://iris-first.invalid.example/")!)
        _ = try? await session.data(from: URL(string: "http://iris-second.invalid.example/")!)

        #expect(proxy.recordedTargets.map(\.host) == ["iris-first.invalid.example", "iris-second.invalid.example"])
    }

    @Test("a target given as a raw IPv4 literal is recorded as that address, not resolved")
    func recordsIPv4Literal() async throws {
        let proxy = try SOCKS5ProxyTestHelper()
        defer { proxy.close() }

        let session = proxiedSession(port: proxy.port)
        _ = try? await session.data(from: URL(string: "http://203.0.113.9/")!)

        #expect(proxy.recordedTargets.map(\.host) == ["203.0.113.9"])
    }
}
