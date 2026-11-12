import Testing
import Foundation
import AppKit
@testable import IrisKit

/// A wide deadline for every test that is not about the deadline: a loaded parallel run's main
/// actor can be seconds behind at the start, and a hop inside a tight bound would miss it.
private let patient: Duration = .seconds(60)

private func door(windowOwner: String? = "com.example.app",
                  responderClass: String = "NSTextView",
                  composer: SelfReportDoor.ComposerState = .init(isPresent: true, isFirstResponder: true, isEmpty: false),
                  turns: SelfReportDoor.TurnState = .init(any: false, count: 0),
                  activation: (isAppActive: Bool, isKeyWindow: Bool) = (true, true),
                  ring: @escaping @Sendable () -> [DiagnosticEventRing.Entry] = { [] },
                  timeout: Duration = patient) -> SelfReportDoor {
    SelfReportDoor(windowOwnerReader: { windowOwner },
                   responderClassReader: { responderClass },
                   composerStateReader: { composer },
                   turnStateReader: { turns },
                   activationReader: { activation },
                   eventRingReader: ring,
                   mainActorTimeout: timeout)
}

private func json(_ snapshot: SelfReportDoor.Snapshot) throws -> String {
    String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
}

@Suite("SelfReportDoor", .timeLimit(.minutes(1)))
struct SelfReportDoorTests {
    @Test("a main actor that does not answer in time is reported as mainActorUnresponsive at the named deadline, not a hang or another error")
    func mainActorTimeoutProducesNamedDiagnosis() async {
        let slow = SelfReportDoor(
            windowOwnerReader: { Thread.sleep(forTimeInterval: 0.3); return "late" },
            responderClassReader: { "x" }, composerStateReader: { .init(isPresent: false, isFirstResponder: false, isEmpty: true) },
            turnStateReader: { .init(any: false, count: 0) }, activationReader: { (true, true) },
            mainActorTimeout: .milliseconds(50))
        let result = await slow.handle(query: .windowOwner, clientId: "a")
        #expect(result.failureValue == .mainActorUnresponsive(afterMilliseconds: 50))
    }

    @Test("the default deadline is the named 500 ms constant")
    func defaultDeadlineIsNamedConstant() {
        #expect(SelfReportDoor.mainActorTimeout == .milliseconds(500))
        let d = SelfReportDoor(windowOwnerReader: { nil }, responderClassReader: { "" },
                               composerStateReader: { .init(isPresent: false, isFirstResponder: false, isEmpty: true) },
                               turnStateReader: { .init(any: false, count: 0) }, activationReader: { (false, false) })
        #expect(d.mainActorTimeout == SelfReportDoor.mainActorTimeout)
    }

    @Test("a backgrounded Iris reports that about itself instead of failing or reading as a broken answer")
    func reportsBackgroundedHonestly() async throws {
        let backgrounded = door(activation: (false, false))
        let snapshot = try #require(await backgrounded.handle(query: .activationState, clientId: "a").successValue)
        #expect(!snapshot.isAppActive)
        #expect(!snapshot.isKeyWindow)
        // And the other queries still answer, tagged with the same honest activation fields.
        let owner = try #require(await backgrounded.handle(query: .windowOwner, clientId: "a").successValue)
        #expect(!owner.isAppActive && owner.query == .windowOwner)
    }

    @Test("every query in the enumeration answers with its own query tag and value kind")
    func everyQueryAnswers() async throws {
        let d = door()
        for query in SelfReportDoor.Query.allCases {
            let snapshot = try #require(await d.handle(query: query, clientId: "a").successValue)
            #expect(snapshot.query == query)
            let text = try json(snapshot)
            #expect(text.contains("\"kind\":\"\(query.rawValue)\""), Comment(rawValue: text))
        }
        #expect(SelfReportDoor.Query.allCases.count == 6)
    }

    @Test("windowOwner reports only a bundle identifier")
    func windowOwnerIsBundleIdOnly() async throws {
        let snapshot = try #require(await door(windowOwner: "com.apple.Safari").handle(query: .windowOwner, clientId: "a").successValue)
        let text = try json(snapshot)
        #expect(text.contains("com.apple.Safari"))
        let none = try #require(await door(windowOwner: nil).handle(query: .windowOwner, clientId: "a").successValue)
        #expect(try json(none).contains("\"bundleId\":null"))
    }

    @MainActor
    @Test("composerState reports booleans about the composer and never its text")
    func composerStateNeverEmitsText() async throws {
        let textView = NSTextView(frame: .zero)
        textView.string = "SECRET DRAFT TEXT"
        let state = SelfReportDoor.composerState(of: textView)
        #expect(state == .init(isPresent: true, isFirstResponder: false, isEmpty: false))
        let snapshot = try #require(await door(composer: state).handle(query: .composerState, clientId: "a").successValue)
        let text = try json(snapshot)
        #expect(!text.contains("SECRET") && !text.contains("DRAFT") && !text.contains("TEXT"), Comment(rawValue: text))
        #expect(SelfReportDoor.composerState(of: nil) == .init(isPresent: false, isFirstResponder: false, isEmpty: true))
        textView.string = ""
        #expect(SelfReportDoor.composerState(of: textView).isEmpty)
    }

    @MainActor
    @Test("responderClassName is a class name and never anything the responder holds")
    func responderClassIsNameOnly() {
        #expect(SelfReportDoor.responderClassName(of: nil) == "none")
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "SECRET WINDOW TITLE"
        let field = NSTextView(frame: .zero)
        field.string = "SECRET BODY"
        window.contentView?.addSubview(field)
        _ = window.makeFirstResponder(field)
        let name = SelfReportDoor.responderClassName(of: window)
        #expect(name.contains("NSTextView"))
        #expect(!name.contains("SECRET"))
    }

    @MainActor
    @Test("composerState tracks first-responder status of the tracked view")
    func composerStateFollowsFirstResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        window.contentView?.addSubview(field)
        #expect(!SelfReportDoor.composerState(of: field).isFirstResponder)
        _ = window.makeFirstResponder(field)
        #expect(SelfReportDoor.composerState(of: field).isFirstResponder)
    }

    @MainActor
    @Test("the composer view registers itself with ComposerFocus when it joins a window and clears itself when it leaves")
    func composerFocusFollowsWindowMembership() {
        defer { ComposerFocus.track(nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let view = KeyCatchingTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        #expect(ComposerFocus.current == nil)
        window.contentView?.addSubview(view)
        #expect(ComposerFocus.current === view)
        view.removeFromSuperview()
        #expect(ComposerFocus.current == nil)
    }

    @MainActor
    @Test("anyTurnInFlight aggregates every conversation without naming one")
    func anyTurnInFlightAggregates() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        var turns = app.anyTurnInFlight()
        #expect(turns.any == false && turns.count == 0)
        app.beginEngineTurn(for: a)
        turns = app.anyTurnInFlight()
        #expect(turns.any && turns.count == 1)
        app.beginEngineTurn(for: b)
        app.beginEngineTurn(for: b)   // two turns on one conversation are still one busy conversation
        turns = app.anyTurnInFlight()
        #expect(turns.any && turns.count == 2)
        app.endEngineTurn(for: a)
        app.endEngineTurn(for: b)
        turns = app.anyTurnInFlight()
        #expect(turns.any && turns.count == 1, "b still has one turn open")
        app.endEngineTurn(for: b)
        #expect(app.anyTurnInFlight().any == false)
        // A `/new` rotation holds its conversation busy without an engine turn (`rotationHold`).
        app.rotationHold = a
        #expect(app.anyTurnInFlight().count == 1 && app.anyTurnInFlight().any)
        app.rotationHold = nil
        #expect(app.anyTurnInFlight().any == false)
    }

    @Test("the event ring encodes every event kind as a flat object with Unix-ms timestamps")
    func eventRingEncodes() async throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000.123)
        let entries: [DiagnosticEventRing.Entry] = [
            .init(timestamp: at, event: .transcriptMouseDown(atWindowPoint: CGPoint(x: 3, y: 4))),
            .init(timestamp: at, event: .transcriptFocusHop(tookFocus: true)),
            .init(timestamp: at, event: .composerAcceptsFirstMouse(true)),
            .init(timestamp: at, event: .windowAppearanceChanged(name: "darkAqua")),
            .init(timestamp: at, event: .composerAppearanceChanged(name: "aqua")),
        ]
        let snapshot = try #require(await door(ring: { entries }).handle(query: .eventRing, clientId: "a").successValue)
        let text = try json(snapshot)
        for kind in ["transcriptMouseDown", "transcriptFocusHop", "composerAcceptsFirstMouse",
                     "windowAppearanceChanged", "composerAppearanceChanged"] {
            #expect(text.contains("\"kind\":\"\(kind)\""), Comment(rawValue: text))
        }
        #expect(text.contains("1700000000123"), Comment(rawValue: text))
        #expect(text.contains("\"x\":3") && text.contains("\"y\":4"), Comment(rawValue: text))
    }

    @Test("a tripwire: no MCPProvider source reads a title, a string value or anything but `.string.isEmpty`, and none uses a reflection route to one")
    func sourceReadsOnlyBoundedFields() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Sources/IrisKit/MCPProvider")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        #expect(files.contains("SelfReportDoor.swift"))
        for name in files {
            let source = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for forbidden in [".title", "attributedString", "textStorage", ".documentView", "representedFilename",
                              "value(forKey", "Mirror(", "perform(", "accessibility"] {
                #expect(!code.contains(forbidden), "\(name) must not use `\(forbidden)`")
            }
            // The leak this guards against is AppKit UI text (a window title, a text view's
            // string) reaching the door's response. `.stringValue`/`.string` pattern-matching the
            // MCP SDK's own `Value` enum (#1067 Task 8's JSON-RPC argument parsing) is a different,
            // legitimate concern with no AppKit text behind it — scope the stricter checks to
            // files that actually import AppKit, the one place that leak could originate.
            guard source.contains("import AppKit") else { continue }
            #expect(!code.contains(".stringValue"), "\(name) must not use `.stringValue`")
            // `.string` as a property read is only ever `.string.isEmpty`; `DateFormatter.string(from:)`
            // is a method call, not a text read, and is the one other spelling in this directory.
            let reads = code.components(separatedBy: ".string").dropFirst().map { $0.hasPrefix(".isEmpty") || $0.hasPrefix("(from:") }
            if name == "SelfReportDoor.swift" {
                #expect(!reads.isEmpty && reads.allSatisfy { $0 }, "the only `.string` access allowed is `.string.isEmpty`")
            } else {
                #expect(reads.allSatisfy { $0 }, "\(name) may not read a `.string` except as `.string.isEmpty`")
            }
        }
    }

    @MainActor
    @Test("the real live() wiring, run over sentinel-laden fixtures, never lets a title or any text into any query's JSON")
    func liveWiringNeverLeaksSentinels() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "SENTINEL-WINDOW-TITLE"
        window.miniwindowTitle = "SENTINEL-MINIWINDOW-TITLE"
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        composer.string = "SENTINEL-COMPOSER-TEXT"
        window.contentView?.addSubview(composer)
        _ = window.makeFirstResponder(composer)
        let app = AppState(); app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        if let index = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[index].title = "SENTINEL-CONVERSATION-TITLE"
        }
        app.beginEngineTurn(for: id)

        let door = SelfReportDoor.live(window: { window }, composer: { composer }, appState: { app },
                                       frontmostBundleId: { "com.example.front" }, isAppActive: { true },
                                       eventRing: { [.init(timestamp: Date(), event: .windowAppearanceChanged(name: "darkAqua"))] },
                                       mainActorTimeout: patient)
        for query in SelfReportDoor.Query.allCases {
            let snapshot = try #require(await door.handle(query: query, clientId: "a").successValue)
            let text = try json(snapshot)
            #expect(!text.contains("SENTINEL"), Comment(rawValue: "\(query): \(text)"))
        }
        // And the wiring does reach the fixtures it was handed (it is not answering from nowhere).
        let owner = try #require(await door.handle(query: .windowOwner, clientId: "a").successValue)
        #expect(try json(owner).contains("com.example.front"))
        let turns = try #require(await door.handle(query: .turnState, clientId: "a").successValue)
        #expect(try json(turns).contains("\"count\":1"))
        let responder = try #require(await door.handle(query: .responderClass, clientId: "a").successValue)
        #expect(try json(responder).contains("NSTextView"))
        let composerSnapshot = try #require(await door.handle(query: .composerState, clientId: "a").successValue)
        #expect(try json(composerSnapshot).contains("\"isEmpty\":false"))
    }

    @Test("a cancelled caller gets .cancelled, not the timeout diagnosis")
    func cancellationIsReportedAsCancelled() async throws {
        let release = DispatchSemaphore(value: 0)
        let slow = SelfReportDoor(
            windowOwnerReader: { _ = release.wait(timeout: .now() + 10); return "late" },
            responderClassReader: { "x" }, composerStateReader: { .init(isPresent: false, isFirstResponder: false, isEmpty: true) },
            turnStateReader: { .init(any: false, count: 0) }, activationReader: { (true, true) },
            mainActorTimeout: patient)
        let task = Task { await slow.handle(query: .windowOwner, clientId: "a") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = try await value(of: task, within: 10)
        release.signal()
        #expect(result.failureValue == .cancelled)
    }

    @Test("a task with no conversation counts as one turn of its own, and an owned one is counted once")
    func unownedTaskCountsAsATurn() {
        let a = UUID(), b = UUID()
        #expect(AppState.aggregateTurns(engineTurnCounts: [:], rotationHold: nil, activeTaskConversations: [nil]) == (true, 1))
        #expect(AppState.aggregateTurns(engineTurnCounts: [:], rotationHold: nil, activeTaskConversations: [nil, nil]) == (true, 2))
        // One conversation seen by all three sources is still one busy conversation.
        #expect(AppState.aggregateTurns(engineTurnCounts: [a: 2], rotationHold: a, activeTaskConversations: [a]) == (true, 1))
        #expect(AppState.aggregateTurns(engineTurnCounts: [a: 1, b: 0], rotationHold: nil, activeTaskConversations: [nil]) == (true, 2))
        #expect(AppState.aggregateTurns(engineTurnCounts: [:], rotationHold: nil, activeTaskConversations: []) == (false, 0))
    }

    @Test("a class name is capped at the named bound")
    func classNameIsBounded() {
        #expect(SelfReportDoor.maxClassNameLength == 128)
        let long = String(repeating: "A", count: 1000)
        #expect(SelfReportDoor.boundedName(long).count == 128)
        #expect(SelfReportDoor.boundedName("NSTextView") == "NSTextView")
    }
}

private extension Result {
    var successValue: Success? { if case .success(let v) = self { return v } else { return nil } }
    var failureValue: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
