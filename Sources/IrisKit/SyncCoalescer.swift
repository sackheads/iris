import Foundation

/// Runs one body at a time, in request order, with at most one run waiting behind the one in
/// progress (#285). The watch layer's sync queue: every ledger write asks for a sync, and a burst
/// of N writes — a replay catch-up, a bulk pause — used to run N full syncs.
///
/// A request that arrives while a run is already *waiting* is satisfied by that run: it has not
/// started, so whatever it reads it reads after this request was made. A request that arrives
/// once the waiting run has started gets a new one behind it, because the started run may have
/// read before the write that prompted the request. So the last run always starts after the last
/// request, and a burst costs at most two runs: the one in progress and the one behind it.
///
/// The waiting slot is cleared when a run starts, *before* its body is called. Clearing early is
/// safe (a request in the gap gets a run of its own, one more than it needed); clearing after the
/// body had read anything would let a request be answered by a read taken before it.
actor SyncCoalescer {
    private let body: @Sendable () async -> Void
    /// The newest run, started or not: the next run waits for it.
    private var tail: Task<Void, Never>?
    /// The run that has not started yet, if any. At most one exists.
    private var waiting: Task<Void, Never>?

    init(_ body: @escaping @Sendable () async -> Void) {
        self.body = body
    }

    /// The run that will answer this request: the waiting one if there is one, else a new one
    /// queued behind the tail. Await its `value` to wait until a run that started after this call
    /// has finished.
    @discardableResult
    func request() -> Task<Void, Never> {
        if let waiting { return waiting }
        let previous = tail
        let next = Task { [weak self] in
            await previous?.value
            await self?.start()
        }
        waiting = next
        tail = next
        return next
    }

    private func start() async {
        waiting = nil
        await body()
    }
}
