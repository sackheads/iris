import Foundation
import Observation

/// #463 decisions 6, 8 and 9: what an app launch does with the store lock's answer. Pure.
enum LaunchDecision: Equatable, Sendable {
    case open
    case wait(StoreLock.Holder?)
    case refuse(LaunchRefusal)

    /// How long a holder may go unnamed before the app treats it as a GUI (decision 6). Refusing
    /// a slow CLI costs a relaunch; waiting forever behind a GUI costs the session.
    static let unknownGrace: TimeInterval = 1

    static func decide(_ claim: StoreLock.Claim, unknownFor: TimeInterval) -> LaunchDecision {
        switch claim {
        case .acquired:
            return .open
        case .held(let holder?):
            switch holder.kind {
            case .runJob, .seedDevHome: return .wait(holder)
            case .app, .perf: return .refuse(.otherApp(pid: holder.pid))
            }
        case .held(nil):
            return unknownFor < unknownGrace ? .wait(nil) : .refuse(.otherApp(pid: nil))
        case .legacy(let pid):
            return .refuse(.legacy(pid: pid))
        case .failed(let detail):
            return .refuse(.failed(detail: detail))
        }
    }
}

/// Why this app quits instead of opening (decisions 4 and 8).
enum LaunchRefusal: Equatable, Sendable {
    case otherApp(pid: Int32?)
    case legacy(pid: Int32)
    case failed(detail: String)

    static let alreadyRunningTitle = "Iris is already running on this home"
    static let cannotLockTitle = "Iris could not lock its store"
    static let linkNotRun = "The link you opened was not run."

    var title: String {
        switch self {
        case .otherApp, .legacy: Self.alreadyRunningTitle
        case .failed: Self.cannotLockTitle
        }
    }

    /// The process to bring forward, when there is one to name.
    var holderPid: Int32? {
        switch self {
        case .otherApp(let pid): pid
        case .legacy(let pid): pid
        case .failed: nil
        }
    }

    func message(hadLinks: Bool) -> String {
        let body: String
        switch self {
        case .otherApp(let pid):
            body = "Another Iris\(pid.map { " (pid \($0))" } ?? "") has this home open, so this one is quitting. Use that one."
        case .legacy(let pid):
            body = "An older Iris build (pid \(pid)) has this home open, so this one is quitting. Quit it, then open Iris again."
        case .failed(let detail):
            body = "Iris will not open its conversations without the lock, so it is quitting. \(detail)"
        }
        return hadLinks ? body + " " + Self.linkNotRun : body
    }
}

/// #463 decisions 9-13: the only state an app has while another process holds its store.
/// Nothing here, and nothing a waiting scene renders, touches `AppState`. Every effect goes
/// through `Seams`, so the tests drive it without a store, a window or a timer.
@MainActor
@Observable
final class LaunchGate {
    enum State: Equatable {
        case waiting(StoreLock.Holder?)
        case open
        case refused(LaunchRefusal)
    }

    struct Seams {
        var claim: @MainActor () -> StoreLock.Claim
        /// `IrisApp.openStore()`: migrations, shipped skills, `AppState.shared`, notifications,
        /// `reapOrphans` and the idle loop (decision 11). Runs once, with the lock held.
        var openStore: @MainActor () -> Void
        /// `startOnce` or `refuseRunJobURLsUntilSetUp`, then the held links, oldest first.
        var finishLaunch: @MainActor (_ links: [URL?], _ dropped: Int) -> Void
        /// A link after the store is open: `AppState.shared.receiveRunJobURL`.
        var deliver: @MainActor (URL?) -> Void
        /// The alert, the holder brought forward, and quit.
        var refuse: @MainActor (LaunchRefusal, _ hadLinks: Bool) -> Void
        /// A repeating main-queue `DispatchSourceTimer` at `interval`, never `Task.sleep`
        /// (invariant 4). Called again with a new interval when the poll rate changes.
        var startPolling: @MainActor (_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> Void
        var stopPolling: @MainActor () -> Void
        /// Orders the "Iris is waiting" panel front without activating Iris (decision 13).
        var showWaitingNotice: @MainActor () -> Void
        var hideWaitingNotice: @MainActor () -> Void
        /// `NSApp.activate`, which did-finish did unconditionally before #463. Skipped only for a
        /// link that launched Iris while it waits (plan note 13).
        var activate: @MainActor () -> Void
        var now: @MainActor () -> Date = { Date() }
    }

    /// Decision 9's poll, while the holder is named.
    static let knownPollInterval: TimeInterval = 1
    /// While the holder is unnamed, so decision 5's second of re-reading is several reads, not one.
    static let unknownPollInterval: TimeInterval = 0.2

    private(set) var state: State = .waiting(nil)
    var isOpen: Bool { state == .open }

    private let seams: Seams
    @ObservationIgnored private var links: [URL?] = []
    @ObservationIgnored private var dropped = 0
    @ObservationIgnored private var didFinish = false
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var refusalShown = false
    @ObservationIgnored private var noticeShown = false
    @ObservationIgnored private var pollInterval: TimeInterval?
    @ObservationIgnored private var unknownSince: Date?

    init(seams: Seams) { self.seams = seams }

    var heldLinkCount: Int { links.count }

    /// `IrisApp.init`: when the lock is free this opens the store right here, as today's `init` did.
    func begin() { apply(seams.claim()) }

    /// One poll: re-claim, re-read the holder's `kind`, re-run decision 3's inode check.
    func poll() {
        guard case .waiting = state else { return }
        apply(seams.claim())
    }

    func didFinishLaunching() {
        guard !didFinish else { return }
        didFinish = true
        switch state {
        case .refused(let refusal):
            showRefusal(refusal)   // the alert activates Iris itself
        case .waiting where !links.isEmpty:
            showNoticeNow()   // a link launched Iris: no activation (decision 13)
        case .waiting:
            seams.activate()
        case .open:
            seams.activate()
            finishIfReady()
        }
    }

    /// Every link from `RunJobURLEvents`. Never logged: it carries a live token.
    func receive(_ url: URL?) {
        if isOpen { return seams.deliver(url) }
        guard links.count < RunJobURLIntake.capacity else { dropped += 1; return }
        links.append(url)
        if didFinish, case .waiting = state { showNoticeNow() }
    }

    /// `applicationWillTerminate`: only an open app has anything to flush (Review Focus 2).
    func willTerminate(flush: () -> Void) {
        if isOpen { flush() }
    }

    /// A held link after did-finish, and the hotkey (which activates first, on purpose).
    func showNoticeNow() {
        guard case .waiting = state else { return }
        noticeShown = true
        seams.showWaitingNotice()
    }

    var sentence: String {
        switch state {
        case .waiting(let holder): Self.waitingSentence(holder)
        case .open: "Iris is open."
        case .refused(let refusal): refusal.title + "."
        }
    }

    static func waitingSentence(_ holder: StoreLock.Holder?) -> String {
        guard let holder else { return "Another Iris process is using this home. Iris will open when it finishes." }
        switch holder.kind {
        case .seedDevHome:
            return "An iris --seed-dev-home is copying into this home (pid \(holder.pid)). Iris will open when it finishes."
        case .runJob, .app, .perf:
            let job = holder.job.map { ", job \(flattened($0))" } ?? ""
            return "An iris --run-job is using this home (pid \(holder.pid)\(job)). Iris will open when it finishes."
        }
    }

    private static func flattened(_ job: String) -> String {
        let line = job.components(separatedBy: .newlines).joined(separator: " ")
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    private func apply(_ claim: StoreLock.Claim) {
        let now = seams.now()
        if case .held(nil) = claim { unknownSince = unknownSince ?? now } else { unknownSince = nil }
        let unknownFor = unknownSince.map { now.timeIntervalSince($0) } ?? 0
        switch LaunchDecision.decide(claim, unknownFor: unknownFor) {
        case .open:
            stopPolling()
            hideNotice()
            seams.openStore()
            state = .open
            finishIfReady()
        case .wait(let holder):
            if state != .waiting(holder) { state = .waiting(holder) }
            poll(every: holder == nil ? Self.unknownPollInterval : Self.knownPollInterval)
        case .refuse(let refusal):
            stopPolling()
            hideNotice()
            state = .refused(refusal)
            if didFinish { showRefusal(refusal) }
        }
    }

    private func poll(every interval: TimeInterval) {
        guard pollInterval != interval else { return }
        if pollInterval != nil { seams.stopPolling() }
        pollInterval = interval
        seams.startPolling(interval) { [weak self] in self?.poll() }
    }

    private func stopPolling() {
        guard pollInterval != nil else { return }
        pollInterval = nil
        seams.stopPolling()
    }

    private func hideNotice() {
        guard noticeShown else { return }
        noticeShown = false
        seams.hideWaitingNotice()
    }

    private func showRefusal(_ refusal: LaunchRefusal) {
        guard !refusalShown else { return }
        refusalShown = true
        seams.refuse(refusal, !links.isEmpty)
    }

    private func finishIfReady() {
        guard isOpen, didFinish, !finished else { return }
        finished = true
        let held = links
        links = []
        seams.finishLaunch(held, dropped)
    }
}
