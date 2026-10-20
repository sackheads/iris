import Foundation
import os

/// The app's price refresh (#239 3c): once at launch when the cache is stale or untrusted, then
/// checked hourly on a dispatch timer and fetched when a day has passed. "Check prices now" in
/// Settings fetches at once. Only the app runs it (`ModelPriceFeed.refresh` refuses any other role).
final class ModelPriceRefresher: Sendable {
    static let shared = ModelPriceRefresher(feed: ModelPriceFeed(paths: .default, keychain: KeychainManager.shared), book: .shared)

    enum Status: Equatable, Sendable {
        case never
        case fetched(asOf: String)
        case failed(String)
    }

    private let feed: ModelPriceFeed
    private let book: PriceBook
    private let queue = DispatchQueue(label: "iris.model-price-refresh")
    private let state = OSAllocatedUnfairLock<(timer: DispatchSourceTimer?, status: Status, running: Bool)>(
        initialState: (nil, .never, false))

    init(feed: ModelPriceFeed, book: PriceBook) {
        self.feed = feed
        self.book = book
    }

    var status: Status { state.withLock { $0.status } }

    /// Starts the hourly check, and checks now. A second call does nothing.
    func start(checkEvery seconds: Double = 3_600) {
        let timer = state.withLock { current -> DispatchSourceTimer? in
            guard current.timer == nil else { return nil }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            current.timer = timer
            return timer
        }
        guard let timer else { return }
        timer.schedule(deadline: .now(), repeating: seconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.feed.isStale() else { return }
            Task { await self.refreshNow() }
        }
        timer.resume()
    }

    /// Fetches now, unless a fetch is already running; the book takes the new prices on success.
    @discardableResult
    func refreshNow(role: ProcessRole? = ProcessRole.current) async -> Status {
        let claimed = state.withLock { s -> Bool in
            guard !s.running else { return false }
            s.running = true
            return true
        }
        guard claimed else { return status }
        let result: Status
        do {
            if let cached = try await feed.refresh(role: role) {
                book.reload()
                result = .fetched(asOf: cached.asOf)
            } else {
                result = .failed("Only the app fetches prices.")
            }
        } catch {
            result = .failed(Self.describe(error))
        }
        state.withLock { $0.status = result; $0.running = false }
        return result
    }

    static func describe(_ error: Error) -> String {
        switch error as? ModelPriceFeed.FetchError {
        case .notHTTPS?: "The price list's address isn't https."
        case .status(let code)?: "The price list answered HTTP \(code)."
        case .tooLarge?: "The price list was over 10 MB."
        case .unparseable?: "The price list couldn't be read."
        case .cannotFingerprint?: "Iris couldn't record the price list in its Keychain item, so it won't use it."
        case nil: (error as? TimeoutError) != nil ? "The price list didn't arrive in time." : "The price list couldn't be fetched."
        }
    }
}
