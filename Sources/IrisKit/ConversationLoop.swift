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
    /// Self-paced (#190 PR 2): the model sets each next delay with `schedule_next_tick`;
    /// `intervalSeconds` is then the first tick's delay only.
    var selfPaced: Bool

    init(prompt: String, intervalSeconds: Double, cap: Int, paused: Bool = false, selfPaced: Bool = false) {
        self.id = UUID()
        self.selfPaced = selfPaced
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
        selfPaced = try c.decodeIfPresent(Bool.self, forKey: .selfPaced) ?? false
    }

    /// The shortest and longest interval `/loop` accepts.
    static let minimumInterval: Double = 60
    static let maximumInterval: Double = 24 * 3600
    /// A self-paced loop's bounds for `schedule_next_tick`, and the delay when a turn ends with no
    /// call: the loop carries on rather than stopping, since a missed call is a lapse, not a
    /// request to end, and the tick cap still bounds it. The first tick comes at the minimum, so
    /// the model sets its own pace from the start.
    static let selfPacedMinimum: Double = 60
    static let selfPacedMaximum: Double = 3600
    static let selfPacedDefault: Double = 20 * 60

    /// `/loop`'s arguments: an interval (`30s`, `5m`, `2h`, `1d`) then the prompt, or the prompt
    /// alone for a self-paced loop.
    enum Parsed: Equatable {
        case start(intervalSeconds: Double, prompt: String)
        case startSelfPaced(prompt: String)
        case stop, pause, resume, status
        case invalid(String)
    }

    static let usage = "Usage: `/loop <interval> <prompt>`, for example `/loop 10m check my open PRs`, or `/loop <prompt>` to let Iris pick each next tick. Also `/loop stop`, `/loop pause`, `/loop resume`, and `/loop` alone for its status."

    static func parse(_ arguments: String) -> Parsed {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "", "status": return .status
        case "stop": return .stop
        case "pause": return .pause
        case "resume": return .resume
        default: break
        }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        guard let seconds = interval(parts[0]) else {
            // A first word that starts with a digit, signed or not, was meant as an interval
            // (`10mn`, `5x`, `-5m`), so it is a typo, not the start of a self-paced prompt.
            if parts[0].drop(while: { $0 == "-" || $0 == "+" }).first?.isNumber == true {
                return .invalid("The interval is a number and a unit: `30s`, `5m`, `2h` or `1d`. " + usage)
            }
            if parts.count == 1, controlWords.contains(parts[0].lowercased()) {
                return .invalid("`/loop \(parts[0])` isn't a loop command. `/loop stop` ends a loop and `/loop pause` pauses it. " + usage)
            }
            return .startSelfPaced(prompt: trimmed)
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
        let text = text.lowercased()
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

    var every: String { selfPaced ? "self-paced" : Self.describe(seconds: intervalSeconds) }
    /// "every 10m", or "self-paced": for the chip, the sidebar and the replies.
    var cadence: String { selfPaced ? "self-paced" : "every \(every)" }

    /// What a tick sends the model, as source `IrisEngine.loopSource`: its own frame, without the
    /// system-event "briefly acknowledge it" suffix, and never starting with a trigger prefix.
    func tickText(number: Int) -> String {
        let pacing = selfPaced
            ? "\n\nThis loop is self-paced: call `schedule_next_tick` with how long to wait before the next tick (\(Self.describe(seconds: Self.selfPacedMinimum)) to \(Self.describe(seconds: Self.selfPacedMaximum))). Without a call, the next tick runs in \(Self.describe(seconds: Self.selfPacedDefault))."
            : ""
        return "Loop tick \(number) of \(cap) (\(cadence)). Do this loop's task again now: \(prompt)\n\nIf nothing has changed since the last tick, say so in one line.\(pacing)"
    }

    /// Clamps a requested delay to the self-paced bounds, and says what was applied (#190 PR 2).
    static func clampedDelay(_ requested: Double) -> (seconds: Double, result: String) {
        let applied = min(max(requested.rounded(), selfPacedMinimum), selfPacedMaximum)
        let next = "Next loop tick in \(describe(seconds: applied))."
        guard applied != requested.rounded() else { return (applied, next) }
        // Never `Int(requested)`: the model can send any finite number, and 1e30 traps (#684 review).
        let asked = requested < selfPacedMinimum ? "less than \(Int(selfPacedMinimum)) s" : "more than \(Int(selfPacedMaximum)) s"
        return (applied, "\(next) You asked for \(asked); the delay is \(Int(selfPacedMinimum)) to \(Int(selfPacedMaximum)) s, so it was clamped.")
    }

    /// One-word prompts that read as a command to the loop rather than a task for it (#684
    /// review): `/loop off` must not start a 50-tick loop whose task is "off".
    static let controlWords: Set<String> = [
        "off", "on", "end", "cancel", "quit", "exit", "halt", "kill", "abort", "start", "restart",
        "help", "list", "show", "info", "enable", "disable", "unpause", "continue", "clear", "reset",
    ]
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
