import Darwin
import Foundation

/// When a process started, as the kernel records it. Two reads that agree name one process: a pid
/// the kernel hands out again belongs to a process that started later.
struct ProcessStart: Equatable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000)
    }

    /// nil when no process has that pid. A process of this user is always readable, so for the
    /// holder (the same user's `--run-job`) nil means it has gone.
    static func of(_ pid: Int32) -> ProcessStart? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessStart(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
}

/// A live Iris process that held the store when this app launched (decision 14): its pid, and when
/// it started, so a pid reused later is never mistaken for it.
struct StoreHolder: Equatable, Sendable {
    let pid: Int32
    let started: ProcessStart
}

/// D6 decision 14: who held the store when this app launched. The app still overwrites the lock,
/// because it owns the store and a lock left by a crashed build must never stop it launching. A
/// live other holder (a `--run-job`) is remembered, so a URL fire waits for it, and the owner is
/// told. The fix, making the app or the CLI yield, is #463.
enum LaunchLock {
    /// Allowance between the clock that stamps a process's start and the one that stamps a file.
    static let clockSlack: TimeInterval = 1

    /// The holder, if the lock names a live process other than this one that could have written
    /// it: one that started before the file was written. One that started later has a pid the
    /// kernel reused after the real holder died, and holds nothing.
    static func foreignHolder(_ state: GUILock.State, lockWritten: Date?, holderStart: ProcessStart?,
                              ownPid: Int32) -> StoreHolder? {
        guard case .held(let pid) = state, pid != ownPid, let lockWritten, let holderStart,
              holderStart.date <= lockWritten.addingTimeInterval(clockSlack) else { return nil }
        return StoreHolder(pid: pid, started: holderStart)
    }

    /// Reads the lock file and nothing else: `IrisApp.init` calls this before `GUILock.acquire()`,
    /// and nothing before the acquire may touch the store.
    static func read(at url: URL, ownPid: Int32 = ProcessInfo.processInfo.processIdentifier,
                     processStart: (Int32) -> ProcessStart? = { ProcessStart.of($0) }) -> StoreHolder? {
        let state = GUILock.state(at: url)
        guard case .held(let pid) = state else { return nil }
        let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return foreignHolder(state, lockWritten: written, holderStart: processStart(pid), ownPid: ownPid)
    }
}

extension AppState {
    /// Decision 14 at launch: remembers a live foreign holder, so a link opened before it finishes
    /// waits for it, and says so in Iris. nil is silent.
    func noteForeignStoreHolder(_ holder: StoreHolder?) {
        foreignStoreHolder = holder?.pid
        foreignStoreHolderStart = holder?.started
        guard let holder else { return }
        appendLaunchNotice(RunJobURL.foreignHolderNotice(pid: holder.pid), to: activityConversationId())
    }

    /// Whether the holder is still the process it was at launch: alive, and, once its start time
    /// was recorded, still that start time. Without a recorded start (a test that sets only the
    /// pid) liveness alone decides, as in D1.
    func isForeignHolderAlive(_ pid: Int32) -> Bool {
        isHolderAlive(pid, started: foreignStoreHolderStart)
    }

    /// The same question for a holder whose start was recorded elsewhere: a waiting fire keeps its
    /// own copy, because a link for another job can clear `foreignStoreHolder` while it waits.
    func isHolderAlive(_ pid: Int32, started recorded: ProcessStart?) -> Bool {
        guard isProcessAlive(pid) else { return false }
        guard let recorded else { return true }
        return processStart(pid) == recorded
    }
}
