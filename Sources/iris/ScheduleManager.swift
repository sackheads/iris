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
    
    // For one-off timers or simple intervals
    let intervalSeconds: Int?
    
    var nextFireAt: Date
    
    func calculateNextFireDate(after date: Date) -> Date {
        if let interval = intervalSeconds {
            return date.addingTimeInterval(TimeInterval(interval))
        }
        
        var comps = DateComponents()
        if let minute = minute { comps.minute = minute }
        if let hour = hour { comps.hour = hour }
        if let day = day { comps.day = day }
        if let month = month { comps.month = month }
        if let weekday = weekday { comps.weekday = weekday }
        
        // If we want it to trigger on matching boundaries, we use .nextTime
        let next = Calendar.current.nextDate(after: date, matching: comps, matchingPolicy: .nextTime) 
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
    
    func schedule(conversationId: UUID?, prompt: String, minute: Int? = nil, hour: Int? = nil, day: Int? = nil, month: Int? = nil, weekday: Int? = nil, intervalSeconds: Int? = nil) {
        lock.lock()
        var job = ScheduledJob(
            conversationId: conversationId,
            prompt: prompt,
            minute: minute,
            hour: hour,
            day: day,
            month: month,
            weekday: weekday,
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
