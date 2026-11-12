import Testing
import Foundation
@testable import IrisKit

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: SuspendingClock.Instant
    init(_ instant: SuspendingClock.Instant) { self.instant = instant }
    var value: SuspendingClock.Instant {
        get { lock.withLock { instant } }
        set { lock.withLock { instant = newValue } }
    }
}

@Suite("MCPProviderRuntime gate constants")
struct MCPProviderRuntimeTests {
    @Test("doorGateCapacity's refillInterval sustains the full capacity per minute, not 1 token per minute")
    func doorGateSustainsFullCapacityPerMinute() async throws {
        try await Self.assertSustainsCapacityPerMinute(capacity: MCPProviderRuntime.doorGateCapacity)
    }

    @Test("mailboxGateCapacity's refillInterval sustains the full capacity per minute, not 1 token per minute")
    func mailboxGateSustainsFullCapacityPerMinute() async throws {
        try await Self.assertSustainsCapacityPerMinute(capacity: MCPProviderRuntime.mailboxGateCapacity)
    }

    private static func assertSustainsCapacityPerMinute(capacity: Int) async throws {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
        let registry = ProviderTokenRegistry(keychain: keychain)
        let token = try registry.issueToken(forClientId: "a")
        let clockBox = ClockBox(SuspendingClock().now)
        let gate = ProviderRequestGate(registry: registry, capacity: capacity,
                                       refillInterval: MCPProviderRuntime.refillInterval(forCapacity: capacity),
                                       now: { clockBox.value })

        // Spend the initial burst.
        for _ in 0..<capacity {
            guard case .admitted = await gate.admit(bearerToken: token) else {
                Issue.record("expected the initial burst of \(capacity) to admit")
                return
            }
        }
        guard case .budgetExceeded = await gate.admit(bearerToken: token) else {
            Issue.record("expected the burst to be exhausted")
            return
        }

        // One full minute later, a sustained rate of `capacity`/minute must have refilled the
        // whole bucket, not just one token — the bug this pins: `capacity: N,
        // refillInterval: .seconds(60)` only refills 1 token per minute once the burst is spent.
        clockBox.value = clockBox.value.advanced(by: .seconds(60))
        var admittedAfterOneMinute = 0
        for _ in 0..<capacity {
            guard case .admitted = await gate.admit(bearerToken: token) else { break }
            admittedAfterOneMinute += 1
        }
        #expect(admittedAfterOneMinute == capacity)
    }
}
