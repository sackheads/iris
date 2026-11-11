import Testing
import Foundation
@testable import IrisKit

private final class InstantBox: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant
    init(_ instant: ContinuousClock.Instant) { self.instant = instant }
    var value: ContinuousClock.Instant {
        get { lock.withLock { instant } }
        set { lock.withLock { instant = newValue } }
    }
}

@Suite("ProviderRequestGate")
struct ProviderRequestGateTests {
    private func registry() -> ProviderTokenRegistry {
        ProviderTokenRegistry(keychain: KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true))
    }

    @Test("a nil or unknown token is unauthorized and never touches the bucket")
    func unknownTokenUnauthorized() async throws {
        let registry = registry()
        let token = try registry.issueToken(forClientId: "c")
        let gate = ProviderRequestGate(registry: registry, capacity: 1, refillInterval: .seconds(60))

        #expect(await gate.admit(bearerToken: nil) == .unauthorized)
        #expect(await gate.admit(bearerToken: "garbage") == .unauthorized)
        // The bucket for "c" is still full capacity: a known token is still admitted.
        #expect(await gate.admit(bearerToken: token) == .admitted(clientId: "c"))
    }

    @Test("a known token is admitted up to capacity, then budget-exceeded")
    func capacityEnforced() async throws {
        let registry = registry()
        let token = try registry.issueToken(forClientId: "c")
        let gate = ProviderRequestGate(registry: registry, capacity: 2, refillInterval: .seconds(60))

        #expect(await gate.admit(bearerToken: token) == .admitted(clientId: "c"))
        #expect(await gate.admit(bearerToken: token) == .admitted(clientId: "c"))
        #expect(await gate.admit(bearerToken: token) == .budgetExceeded)
    }

    @Test("two different clients each get their own bucket")
    func perClientBuckets() async throws {
        let registry = registry()
        let tokenA = try registry.issueToken(forClientId: "a")
        let tokenB = try registry.issueToken(forClientId: "b")
        let gate = ProviderRequestGate(registry: registry, capacity: 1, refillInterval: .seconds(60))

        #expect(await gate.admit(bearerToken: tokenA) == .admitted(clientId: "a"))
        #expect(await gate.admit(bearerToken: tokenA) == .budgetExceeded)
        // b's bucket is untouched by a's exhaustion.
        #expect(await gate.admit(bearerToken: tokenB) == .admitted(clientId: "b"))
    }

    @Test("a bucket refills over time, admitting again once enough has elapsed")
    func refillsOverTime() async throws {
        let registry = registry()
        let token = try registry.issueToken(forClientId: "c")
        let clockBox = InstantBox(ContinuousClock().now)
        let gate = ProviderRequestGate(registry: registry, capacity: 1, refillInterval: .milliseconds(50),
                                       now: { clockBox.value })

        #expect(await gate.admit(bearerToken: token) == .admitted(clientId: "c"))
        #expect(await gate.admit(bearerToken: token) == .budgetExceeded)
        clockBox.value = clockBox.value.advanced(by: .milliseconds(60))
        #expect(await gate.admit(bearerToken: token) == .admitted(clientId: "c"))
    }
}
