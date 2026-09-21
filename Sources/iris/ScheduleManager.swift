import Foundation
import AppKit

struct ScheduledJob: Codable, Identifiable {
    var id: UUID = UUID()
    let conversationId: UUID?
    let prompt: String

    // Date components for matching. Nil means "any/wildcard"
    let minute: Int?
    let hour: Int?
    let day: Int?
    let month: Int?
    let weekday: Int? // 1 = Sunday, 2 = Monday, etc.
    /// Any subset of 1-7 (Sunday...Saturday), any order, duplicates ignored. Preferred over
    /// `weekday` when non-empty (#156: "every weekday" needs more than one day). `weekday` is kept
    /// for jobs persisted before this field existed and for callers that still send it.
    let weekdays: [Int]?

    // For one-off timers or simple intervals
    let intervalSeconds: Int?

    var nextFireAt: Date

    init(id: UUID = UUID(), conversationId: UUID?, prompt: String, minute: Int? = nil, hour: Int? = nil, day: Int? = nil, month: Int? = nil, weekday: Int? = nil, weekdays: [Int]? = nil, intervalSeconds: Int? = nil, nextFireAt: Date) {
        self.id = id
        self.conversationId = conversationId
        self.prompt = prompt
        self.minute = minute
        self.hour = hour
        self.day = day
        self.month = month
        self.weekday = weekday
        self.weekdays = weekdays
        self.intervalSeconds = intervalSeconds
        self.nextFireAt = nextFireAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationId, prompt, minute, hour, day, month, weekday, weekdays, intervalSeconds, nextFireAt
    }

    // Hand-written to satisfy invariant 1: a jobs file written before `weekdays` existed (or any
    // future field) must still decode every job rather than dropping the row.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        conversationId = try container.decodeIfPresent(UUID.self, forKey: .conversationId)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        minute = try container.decodeIfPresent(Int.self, forKey: .minute)
        hour = try container.decodeIfPresent(Int.self, forKey: .hour)
        day = try container.decodeIfPresent(Int.self, forKey: .day)
        month = try container.decodeIfPresent(Int.self, forKey: .month)
        weekday = try container.decodeIfPresent(Int.self, forKey: .weekday)
        weekdays = try container.decodeIfPresent([Int].self, forKey: .weekdays)
        intervalSeconds = try container.decodeIfPresent(Int.self, forKey: .intervalSeconds)
        nextFireAt = try container.decodeIfPresent(Date.self, forKey: .nextFireAt) ?? Date()
    }

    /// `weekdays` if non-empty, else `weekday` lifted into a single-element array; filtered to
    /// 1...7 and de-duplicated, preserving first-seen order. Nil if neither field yields a day.
    ///
    /// The tool handler already drops out-of-range values before they ever reach a stored job, so
    /// this is a decode-time-only concern in practice — but if `weekdays` is present and every one
    /// of its entries is out of range, this returns nil rather than silently keeping something.
    /// `calculateNextFireDate`'s `effectiveWeekdays?.first ?? weekday` then falls through to the
    /// legacy `weekday` field when present — a deliberate fallback, not a bug, since a job written
    /// before `weekdays` existed must keep firing on its original day.
    var effectiveWeekdays: [Int]? {
        let candidate: [Int]
        if let weekdays, !weekdays.isEmpty {
            candidate = weekdays
        } else if let weekday {
            candidate = [weekday]
        } else {
            return nil
        }
        var seen: Set<Int> = []
        let filtered = candidate.filter { (1...7).contains($0) && seen.insert($0).inserted }
        return filtered.isEmpty ? nil : filtered
    }

    func calculateNextFireDate(after date: Date, calendar: Calendar = .current) -> Date {
        if let interval = intervalSeconds {
            return date.addingTimeInterval(TimeInterval(interval))
        }

        func candidateDate(weekday: Int?) -> Date? {
            var comps = DateComponents()
            if let minute = minute { comps.minute = minute }
            if let hour = hour { comps.hour = hour }
            if let day = day { comps.day = day }
            if let month = month { comps.month = month }
            if let weekday = weekday { comps.weekday = weekday }
            // If we want it to trigger on matching boundaries, we use .nextTime
            return calendar.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
        }

        if let days = effectiveWeekdays, days.count > 1 {
            let candidates = days.compactMap { candidateDate(weekday: $0) }
            return candidates.min() ?? date.addingTimeInterval(86400)
        }

        let next = candidateDate(weekday: effectiveWeekdays?.first ?? weekday)
        return next ?? date.addingTimeInterval(86400) // Fallback just in case
    }
}

class ScheduleManager: @unchecked Sendable {
    static let shared = ScheduleManager()
    
    private let lock = NSLock()
    private var jobs: [ScheduledJob] = []
    
    private var _onJobFired: (@Sendable (String, UUID?) async -> Void)?
    var onJobFired: (@Sendable (String, UUID?) async -> Void)? {
        get { lock.withLock { _onJobFired } }
        set { lock.withLock { _onJobFired = newValue } }
    }
    
    private var isRunning = false
    private var evaluationTask: Task<Void, Never>?
    
    private init() {
        loadJobs()
        
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluateJobs(fromWake: true)
        }
    }
    
    func start() {
        let alreadyRunning = lock.withLock { () -> Bool in
            if isRunning { return true }
            isRunning = true
            return false
        }
        if alreadyRunning { return }

        evaluationTask?.cancel()
        evaluationTask = Task {
            while !Task.isCancelled {
                self.evaluateJobs(fromWake: false)
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            }
        }
    }
    
    func schedule(conversationId: UUID?, prompt: String, minute: Int? = nil, hour: Int? = nil, day: Int? = nil, month: Int? = nil, weekday: Int? = nil, weekdays: [Int]? = nil, intervalSeconds: Int? = nil) {
        lock.lock()
        var job = ScheduledJob(
            conversationId: conversationId,
            prompt: prompt,
            minute: minute,
            hour: hour,
            day: day,
            month: month,
            weekday: weekday,
            weekdays: weekdays,
            intervalSeconds: intervalSeconds,
            nextFireAt: Date() // placeholder
        )
        job.nextFireAt = job.calculateNextFireDate(after: Date())
        self.jobs.append(job)
        self.saveJobs()
        lock.unlock()
    }
    
    private func evaluateJobs(fromWake: Bool) {
        let now = Date()
        var firedJobs: [ScheduledJob] = []
        var updatedJobs: [ScheduledJob] = []
        
        lock.lock()
        for var job in self.jobs {
            if job.nextFireAt <= now {
                firedJobs.append(job)
                job.nextFireAt = job.calculateNextFireDate(after: now)
                updatedJobs.append(job) 
            } else {
                updatedJobs.append(job)
            }
        }
        
        if !firedJobs.isEmpty {
            self.jobs = updatedJobs
            self.saveJobs()
        }
        let firedCallback = self._onJobFired
        lock.unlock()
        
        if !firedJobs.isEmpty, let callback = firedCallback {
            for job in firedJobs {
                Task {
                    await callback(job.prompt, job.conversationId)
                }
            }
        }
    }
    
    private func loadJobs() {
        if let data = IrisDefaults.store.data(forKey: "iris_scheduled_jobs"),
           let decoded = try? JSONDecoder().decode([ScheduledJob].self, from: data) {
            lock.withLock { self.jobs = decoded }
        }
    }
    
    private func saveJobs() {
        if let data = try? JSONEncoder().encode(jobs) {
            IrisDefaults.store.set(data, forKey: "iris_scheduled_jobs")
        }
    }
}
