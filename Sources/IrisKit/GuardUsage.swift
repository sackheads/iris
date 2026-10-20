import Foundation
import os

/// Where a cloud guard call's tokens are charged (#689): Vibecop's cloud engine and the tier-3
/// canary run on the primary provider, and their usage used to be thrown away. The engine or
/// runner whose work caused the call binds a sink for the call's task; `CloudAuxiliaryEngine`
/// reports to it. A task-local, so it reaches `Task {}` children (`withTimeout` keeps them) but
/// not detached work, and a report with no sink bound is logged once per role, never dropped
/// silently, so a path that was missed shows up.
enum GuardUsage {
    struct Sink: Sendable {
        let record: @Sendable (UsageMetadata) async -> Void
    }

    @TaskLocal static var sink: Sink?

    private static let unattributed = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Charges `usage` to the bound sink, or logs once that `role`'s guard usage had nowhere to go.
    static func report(_ usage: UsageMetadata?, role: String) async {
        guard let usage else { return }
        if let sink {
            await sink.record(usage)
        } else if unattributed.withLock({ $0.insert(role).inserted }) {
            print("Unattributed guard usage (\(role)): a cloud guard call ran with no conversation or run to charge (#689).")
        }
    }

    /// Whether `role` has had unattributed usage in this process; for tests.
    static func wasUnattributed(_ role: String) -> Bool { unattributed.withLock { $0.contains(role) } }

    /// The sink for a conversation: its tokens, and through them its job run's budget, as any of
    /// the conversation's own model rounds are charged (`AppState.updateTokenUsage`).
    @MainActor
    static func charging(_ conversationId: UUID, in state: AppState?) -> Sink {
        Sink { [weak state] usage in
            await MainActor.run { state?.updateTokenUsage(for: conversationId, usage: usage) }
        }
    }
}
