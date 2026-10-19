import Foundation

/// A conversation's `/loop` (#190): its own prompt re-run on a cadence, in the same visible
/// conversation, on `/goal`'s reprompt machinery. Not a job: no `Job` row, no scheduler, never
/// unattended (`docs/specs/2026-10-19-loop.md`).
struct ConversationLoop: Codable, Equatable, Sendable {
    /// This loop's own id: a tick scheduled for one loop never fires into a later one.
    var id: UUID
    /// What each tick asks, in the person's own words.
    var prompt: String
    var intervalSeconds: Double
    /// Ticks still to run before the loop stops; `cap` is what `/loop` started it with.
    var ticksLeft: Int
    var cap: Int
    /// Paused loops schedule nothing. Every loop comes back paused after a relaunch.
    var paused: Bool

    init(prompt: String, intervalSeconds: Double, cap: Int, paused: Bool = false) {
        self.id = UUID()
        self.prompt = prompt
        self.intervalSeconds = intervalSeconds
        self.ticksLeft = cap
        self.cap = cap
        self.paused = paused
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        prompt = try c.decode(String.self, forKey: .prompt)
        intervalSeconds = try c.decode(Double.self, forKey: .intervalSeconds)
        cap = try c.decodeIfPresent(Int.self, forKey: .cap) ?? ConfigManager.defaultLoopTickCap
        ticksLeft = try c.decodeIfPresent(Int.self, forKey: .ticksLeft) ?? cap
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? true
    }

    /// The shortest and longest interval `/loop` accepts.
    static let minimumInterval: Double = 60
    static let maximumInterval: Double = 24 * 3600

    /// `/loop`'s arguments: an interval (`30s`, `5m`, `2h`, `1d`) then the prompt.
    enum Parsed: Equatable {
        case start(intervalSeconds: Double, prompt: String)
        case stop, pause, resume, status
        case invalid(String)
    }

    static let usage = "Usage: `/loop <interval> <prompt>`, for example `/loop 10m check my open PRs`. Also `/loop stop`, `/loop pause`, `/loop resume`, and `/loop` alone for its status."

    static func parse(_ arguments: String) -> Parsed {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "": return .status
        case "stop": return .stop
        case "pause": return .pause
        case "resume": return .resume
        default: break
        }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        guard let seconds = interval(parts[0]) else {
            return .invalid("The interval comes first, as a number and a unit: `30s`, `5m`, `2h` or `1d`. " + usage)
        }
        guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid("Say what each tick should do after the interval. " + usage)
        }
        guard seconds >= minimumInterval, seconds <= maximumInterval else {
            return .invalid("A loop runs at most once a minute and at least once a day; \(parts[0]) is outside that.")
        }
        return .start(intervalSeconds: seconds, prompt: parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `5m` as seconds, or nil.
    static func interval(_ text: String) -> Double? {
        guard let unit = text.last, let number = Double(text.dropLast()), number > 0, number.isFinite else { return nil }
        switch unit {
        case "s": return number
        case "m": return number * 60
        case "h": return number * 3600
        case "d": return number * 86400
        default: return nil
        }
    }

    /// `600` as "10m", for the chip and the replies.
    static func describe(seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s % 86400 == 0 { return "\(s / 86400)d" }
        if s % 3600 == 0 { return "\(s / 3600)h" }
        if s % 60 == 0 { return "\(s / 60)m" }
        return "\(s)s"
    }

    var every: String { Self.describe(seconds: intervalSeconds) }

    /// What a tick sends the model, as source `IrisEngine.loopSource`: its own frame, without the
    /// system-event "briefly acknowledge it" suffix, and never starting with a trigger prefix.
    func tickText(number: Int) -> String {
        "Loop tick \(number) of \(cap) (every \(every)). Do this loop's task again now: \(prompt)\n\nIf nothing has changed since the last tick, say so in one line."
    }
}

/// A one-shot wait on `DispatchTime`, which is uptime: time the Mac spends asleep does not count
/// (#608), and nothing waits on the cooperative pool (Invariant 4). Ends early when the waiting
/// task is cancelled, so a cancelled tick never runs.
enum UptimeWait {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var done = false
        func set(_ c: CheckedContinuation<Void, Never>) {
            let resumeNow = lock.withLock { () -> Bool in
                if done { return true }
                continuation = c
                return false
            }
            if resumeNow { c.resume() }
        }
        func fire() {
            let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard !done else { return nil }
                done = true
                defer { continuation = nil }
                return continuation
            }
            c?.resume()
        }
    }

    static func seconds(_ seconds: Double) async {
        let once = Once()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                once.set(c)
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds)) { once.fire() }
            }
        } onCancel: {
            once.fire()
        }
    }
}
