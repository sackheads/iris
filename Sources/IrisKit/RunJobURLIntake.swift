import Foundation

/// Where a run-job link waits while Iris starts (D2, owner ruling C2). A cold launch delivers the
/// link between `applicationWillFinishLaunching` and `applicationDidFinishLaunching`, before the
/// job bookkeeping `IrisEngine.start()` does first, which closes every `running` row as a dead
/// process's. So links wait here until that is done, in order, and are then handled as if they had
/// just arrived. A link that came while another process held the store waited at `LaunchGate`
/// first, and arrives here at `finishLaunch` (#463 decision 12).
enum RunJobURLIntake: Equatable, Sendable {
    /// Waiting for the job bookkeeping, holding these links.
    case starting([URL])
    case ready
    /// Launched before setup was finished, so the engine was not started: links are refused until
    /// setup starts it.
    case notSetUp

    /// Links held while starting. A flood beyond this is refused at once, in one coalesced line.
    static let capacity = 16
}

extension AppState {
    /// The one way in for a link from outside (`RunJobURLEvents`). nil is an event that carried no
    /// link a URL could be made of. `handleRunJobURL` stays the handler and the test entry point.
    func receiveRunJobURL(_ url: URL?) {
        guard let url else {
            refuseURLFire(job: nil, reason: RunJobURL.Refusal.unreadable.sentence, to: activityConversationId())
            return
        }
        switch urlIntake {
        case .ready:
            handleRunJobURL(url)
        case .notSetUp:
            refuseURLFire(job: nil, reason: RunJobURL.notSetUpReason, to: activityConversationId())
        case .starting(var held):
            guard held.count < RunJobURLIntake.capacity else {
                refuseURLFire(job: nil, reason: RunJobURL.startupFloodReason, to: activityConversationId())
                return
            }
            held.append(url)
            urlIntake = .starting(held)
        }
    }

    /// The job bookkeeping is done (`IrisEngine.configureJobBookkeeping`): every held link is
    /// handled, oldest first. Also the way out of `.notSetUp`, when setup's `start()` gets here.
    func jobsBecameReady() {
        let held: [URL]
        if case .starting(let waiting) = urlIntake { held = waiting } else { held = [] }
        urlIntake = .ready
        for url in held { handleRunJobURL(url) }
    }

    /// Launch found Iris not set up, so nothing will start the engine until the wizard finishes.
    func refuseRunJobURLsUntilSetUp() {
        guard case .starting(let held) = urlIntake else { return }
        urlIntake = .notSetUp
        for _ in held { refuseURLFire(job: nil, reason: RunJobURL.notSetUpReason, to: activityConversationId()) }
    }

    /// The gate's overflow, said once in Iris after the launch completes. The links were never
    /// read, so nothing can say which jobs they named.
    func noteLinksDroppedWhileWaiting(_ count: Int) {
        guard count > 0 else { return }
        appendMessage(role: .system, content: RunJobURL.droppedWhileWaitingLine(count), to: activityConversationId())
    }

    /// The rule `ChatView` uses to choose between the setup wizard and starting the engine.
    static func isSetUp(defaults: UserDefaults = IrisDefaults.store, config: ConfigManager = .shared) -> Bool {
        defaults.bool(forKey: "HAS_COMPLETED_SETUP") && config.isConfigured
    }

    /// Starts the engine unless something already has: launch (a link's cold start opens no
    /// window, so `ChatView.onAppear` may never run) and every window appear. The setup wizard's
    /// finish calls `start()` itself, which reloads plugins and MCP servers (#472).
    func startOnce() {
        guard !engineStarted else { return }
        start()
        #if DEBUG
        DebugStreamProbe.startIfAsked(state: self)   // #541's measurement branch only
        #endif
    }
}
