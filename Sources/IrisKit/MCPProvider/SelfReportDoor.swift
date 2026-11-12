import AppKit
import Foundation

/// The app-level self-report door (#1067): a small, enumerated set of read-only questions a dev's
/// MCP client may ask Iris about its own UI state, answered with bounded fields only. No
/// transcript text, no conversation or window titles, no composer text: every field is a bool, a
/// count, a bundle identifier or a class name.
///
/// A plain `nonisolated` struct on purpose. The `@MainActor` reads are injected closures, and each
/// `handle` makes exactly one hop to the main actor, raced against a dispatch-timer deadline
/// (`withTimeout`, never `Task.sleep`): a main actor that does not answer in time is itself the
/// diagnosis (`.mainActorUnresponsive`), not an error to paper over.
///
/// Admission is not this type's business. `Task 8`'s `handleAuthenticated` admits a request
/// (token, then budget) before any door call, so `handle` takes the already-resolved `clientId`
/// and never charges a gate, which keeps one logical request from costing two units.
struct SelfReportDoor: Sendable {
    static let mainActorTimeout: Duration = .milliseconds(500)

    enum Query: String, Sendable, CaseIterable {
        case windowOwner, responderClass, composerState, turnState, activationState, eventRing
    }

    /// Whether the composer is the window's current first responder and whether it holds any text.
    /// Both are derived booleans; the text itself is never read out. `isPresent` is false when no
    /// composer is tracked at all (no window yet), so "not first responder" and "empty" are not
    /// reported as facts about a view that does not exist.
    struct ComposerState: Sendable, Codable, Equatable {
        let isPresent: Bool
        let isFirstResponder: Bool
        let isEmpty: Bool
    }

    struct TurnState: Sendable, Codable, Equatable {
        let any: Bool
        let count: Int
    }

    /// What the main-actor read produced for the asked query. One shape per query, encoded as a
    /// flat `{"kind": ..., fields}` object.
    enum Value: Sendable, Encodable {
        case windowOwner(bundleId: String?)
        case responderClass(String)
        case composerState(ComposerState)
        case turnState(TurnState)
        case activationState
        case eventRing([DiagnosticEventRing.Entry])

        private enum CodingKeys: String, CodingKey { case kind, bundleId, className, composer, turn, events }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .windowOwner(let bundleId):
                try c.encode("windowOwner", forKey: .kind)
                try c.encode(bundleId, forKey: .bundleId)
            case .responderClass(let name):
                try c.encode("responderClass", forKey: .kind)
                try c.encode(name, forKey: .className)
            case .composerState(let state):
                try c.encode("composerState", forKey: .kind)
                try c.encode(state, forKey: .composer)
            case .turnState(let state):
                try c.encode("turnState", forKey: .kind)
                try c.encode(state, forKey: .turn)
            case .activationState:
                try c.encode("activationState", forKey: .kind)
            case .eventRing(let entries):
                try c.encode("eventRing", forKey: .kind)
                try c.encode(entries, forKey: .events)
            }
        }
    }

    /// Every snapshot says whether Iris is the active app and its window the key one, so a
    /// backgrounded Iris reports that about itself rather than looking like a broken answer.
    struct Snapshot: Sendable, Encodable {
        let query: Query
        let isAppActive: Bool
        let isKeyWindow: Bool
        let value: Value

        private enum CodingKeys: String, CodingKey { case query, isAppActive, isKeyWindow, value }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(query.rawValue, forKey: .query)
            try c.encode(isAppActive, forKey: .isAppActive)
            try c.encode(isKeyWindow, forKey: .isKeyWindow)
            try c.encode(value, forKey: .value)
        }
    }

    enum DoorError: Error, Equatable {
        /// The main actor did not answer within the deadline. The literal diagnosis, never mapped
        /// to a different error.
        case mainActorUnresponsive(afterMilliseconds: Int)
        /// The caller went away (the request was cancelled) before the main actor answered.
        case cancelled
        /// `withTimeout` threw something other than its two documented errors. Named rather than
        /// folded into `.cancelled` or the timeout, so a future third error cannot be misreported.
        case unexpected(errorType: String)
    }

    /// `MainActor`-isolated closures are `Sendable` by construction, so this struct is too.
    let windowOwnerReader: @MainActor () -> String?
    let responderClassReader: @MainActor () -> String
    let composerStateReader: @MainActor () -> ComposerState
    let turnStateReader: @MainActor () -> TurnState
    let activationReader: @MainActor () -> (isAppActive: Bool, isKeyWindow: Bool)
    let eventRingReader: @Sendable () -> [DiagnosticEventRing.Entry]
    /// Instance-level so a test can shrink the deadline for the timeout case and widen it for the
    /// rest (a loaded run's main actor can be seconds behind, AGENTS.md). Production never passes it.
    let mainActorTimeout: Duration

    init(windowOwnerReader: @escaping @MainActor () -> String?,
         responderClassReader: @escaping @MainActor () -> String,
         composerStateReader: @escaping @MainActor () -> ComposerState,
         turnStateReader: @escaping @MainActor () -> TurnState,
         activationReader: @escaping @MainActor () -> (isAppActive: Bool, isKeyWindow: Bool),
         eventRingReader: @escaping @Sendable () -> [DiagnosticEventRing.Entry] = { DiagnosticEventRing.shared.snapshot() },
         mainActorTimeout: Duration = SelfReportDoor.mainActorTimeout) {
        self.windowOwnerReader = windowOwnerReader
        self.responderClassReader = responderClassReader
        self.composerStateReader = composerStateReader
        self.turnStateReader = turnStateReader
        self.activationReader = activationReader
        self.eventRingReader = eventRingReader
        self.mainActorTimeout = mainActorTimeout
    }

    /// The production door, reading the real app. Every closure runs on the main actor. Each source
    /// is a parameter, defaulting to the real global, so a test can run the real wiring (this
    /// function, not a copy of it) over sentinel-laden fixtures and assert no sentinel reaches a
    /// snapshot.
    static func live(window: @escaping @MainActor () -> NSWindow? = { MainWindow.current },
                     composer: @escaping @MainActor () -> NSTextView? = { ComposerFocus.current },
                     appState: @escaping @MainActor () -> AppState = { AppState.shared },
                     frontmostBundleId: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
                     isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
                     eventRing: @escaping @Sendable () -> [DiagnosticEventRing.Entry] = { DiagnosticEventRing.shared.snapshot() },
                     mainActorTimeout: Duration = SelfReportDoor.mainActorTimeout) -> SelfReportDoor {
        SelfReportDoor(
            windowOwnerReader: { frontmostBundleId() },
            responderClassReader: { Self.responderClassName(of: window()) },
            composerStateReader: { Self.composerState(of: composer()) },
            turnStateReader: {
                let turns = appState().anyTurnInFlight()
                return TurnState(any: turns.any, count: turns.count)
            },
            activationReader: { (isAppActive(), window()?.isKeyWindow ?? false) },
            eventRingReader: eventRing,
            mainActorTimeout: mainActorTimeout)
    }

    /// A class name is bounded: SwiftUI's generic type names can run to hundreds of characters, and
    /// every field this door emits has a fixed upper size.
    static let maxClassNameLength = 128

    static func boundedName(_ name: String) -> String { String(name.prefix(maxClassNameLength)) }

    /// The class name of the window's first responder, never anything it holds.
    @MainActor
    static func responderClassName(of window: NSWindow?) -> String {
        guard let responder = window?.firstResponder else { return "none" }
        return boundedName(String(describing: type(of: responder)))
    }

    /// Booleans about the composer, never its text: `isEmpty` is the only thing derived from the
    /// string, and the string itself is dropped on the same line.
    @MainActor
    static func composerState(of textView: NSTextView?) -> ComposerState {
        guard let textView else { return ComposerState(isPresent: false, isFirstResponder: false, isEmpty: true) }
        return ComposerState(isPresent: true,
                             isFirstResponder: textView.window?.firstResponder === textView,
                             isEmpty: textView.string.isEmpty)
    }

    /// `clientId` is already resolved and already admitted (see the type's comment); it is accepted
    /// so the call site stays honest about whose request this is, and is never read from the query.
    func handle(query: Query, clientId: String) async -> Result<Snapshot, DoorError> {
        let windowOwnerReader = windowOwnerReader
        let responderClassReader = responderClassReader
        let composerStateReader = composerStateReader
        let turnStateReader = turnStateReader
        let activationReader = activationReader
        let eventRingReader = eventRingReader
        let timeoutSeconds = Self.seconds(mainActorTimeout)
        let timeoutMilliseconds = Int((timeoutSeconds * 1000).rounded())
        do {
            // One hop for the activation fields every snapshot carries and the query's own read.
            let snapshot = try await withTimeout(seconds: timeoutSeconds) {
                await MainActor.run { () -> Snapshot in
                    let activation = activationReader()
                    let value: Value
                    switch query {
                    case .windowOwner: value = .windowOwner(bundleId: windowOwnerReader())
                    case .responderClass: value = .responderClass(responderClassReader())
                    case .composerState: value = .composerState(composerStateReader())
                    case .turnState: value = .turnState(turnStateReader())
                    case .activationState: value = .activationState
                    case .eventRing: value = .eventRing(eventRingReader())
                    }
                    return Snapshot(query: query, isAppActive: activation.isAppActive,
                                    isKeyWindow: activation.isKeyWindow, value: value)
                }
            }
            return .success(snapshot)
        } catch is TimeoutError {
            return .failure(.mainActorUnresponsive(afterMilliseconds: timeoutMilliseconds))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.unexpected(errorType: Self.boundedName(String(describing: type(of: error)))))
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
