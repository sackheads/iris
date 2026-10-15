import Testing
import Foundation
@testable import IrisKit

/// #463 decision 14: `AppState.shared` traps unless this process is the app and holds its home's
/// store lock. Every build and every test traps, with no disarm, so the trapping cases run in exit
/// tests: each is a child process of its own, where setting `ProcessRole` and claiming the
/// (per-process, temporary) test home's lock touch nothing the shared test process can see.
@Suite("AppState.shared trap (#463)", .timeLimit(.minutes(1)))
struct SharedAppStateTrapTests {
    @Test("the rule: only the app, and only while it holds the store")
    func rule() {
        #expect(ProcessRole.mayUseSharedAppState(role: .app, holdsStore: true))
        #expect(!ProcessRole.mayUseSharedAppState(role: .app, holdsStore: false))
        for role in [ProcessRole.runJob, .perf, .bench, .seed] {
            #expect(!ProcessRole.mayUseSharedAppState(role: role, holdsStore: true))
        }
        #expect(!ProcessRole.mayUseSharedAppState(role: nil, holdsStore: true))
    }

    @Test("a process that never set a role traps")
    func trapsWithNoRole() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run { _ = AppState.shared }
        }
    }

    @Test("the app traps before it holds the store")
    func appWithoutTheLockTraps() async {
        await #expect(processExitsWith: .failure) {
            ProcessRole.set(.app)
            await MainActor.run { _ = AppState.shared }
        }
    }

    @Test("the app holding its store gets .shared")
    func appWithTheLockGetsShared() async {
        await #expect(processExitsWith: .success) {
            ProcessRole.set(.app)
            guard StoreLock.claim(at: IrisPaths.default.storeLockFile, kind: .app) == .acquired else { exit(3) }
            await MainActor.run { _ = AppState.shared }
        }
    }

    @Test("--run-job traps even while it holds the store")
    func runJobTraps() async {
        await #expect(processExitsWith: .failure) {
            ProcessRole.set(.runJob)
            // Exit 0 fails the test: a claim that did not acquire would prove nothing about the lock.
            guard StoreLock.claim(at: IrisPaths.default.storeLockFile, kind: .runJob) == .acquired else { exit(0) }
            await MainActor.run { _ = AppState.shared }
        }
    }

    @Test("#489: in a --run-job process, skill writes invalidate the run's own engine and reach nothing shared")
    func runJobSkillWritesStayOnTheRunsEngine() async {
        await #expect(processExitsWith: .success) {
            guard await RunJobSkillScenario.run() else { exit(2) }
        }
    }

    @Test("Review Focus 5: AppState.shared appears only in the GUI shell")
    func sharedAppearsOnlyInTheGUIShell() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // The GUI shell only: `IrisApp.swift` (Task 7 moved `IrisApp` and `AppDelegate` out of
        // `iris.swift`, which is mostly `IrisEngine`, the headless path), the gate's app seams,
        // and the views. `AppState.swift` is scanned too: its declaration is `static var shared`,
        // which neither pattern matches.
        // Counted per file, not just named: a new use in an exempt file must change its count here,
        // on purpose, rather than ride in under the file's exemption.
        let allowed: [String: Int] = ["IrisApp.swift": 9, "LaunchGate+App.swift": 6, "WaitingView.swift": 2,
                                      "ChatView.swift": 1, "SettingsView.swift": 1, "PluginsSettingsView.swift": 2]
        // `AppState.shared`, and the implicit-member spellings `: AppState = .shared` and
        // `AppState? = .shared`, which a literal-text match would miss.
        // Simple word boundaries: under the default Unicode ones `shared.startOnce` is one word, so
        // `\b` after `shared` never matched a use followed by a member access.
        let use = try Regex(#"\bAppState\.shared\b|:\s*AppState[?!]?\s*=\s*\.shared\b"#).wordBoundaryKind(.simple)
        var offenders: [String] = []
        var shellCounts: [String: Int] = [:]
        for dir in ["Sources/IrisKit", "Tests/irisTests"] {
            let base = root.appendingPathComponent(dir)
            for name in try FileManager.default.contentsOfDirectory(atPath: base.path) where name.hasSuffix(".swift") {
                guard name != "SharedAppStateTrapTests.swift" else { continue }
                let exempt = dir == "Sources/IrisKit" && allowed[name] != nil
                let text = try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)
                for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//"), code.firstMatch(of: use) != nil else { continue }
                    if exempt { shellCounts[name, default: 0] += 1 } else { offenders.append("\(dir)/\(name):\(index + 1)") }
                }
            }
        }
        #expect(offenders.isEmpty, "AppState.shared outside the GUI shell: \(offenders)")
        #expect(shellCounts == allowed, "AppState.shared lines per GUI-shell file changed: \(shellCounts), expected \(allowed)")
    }
}

/// #489, in a child process with `ProcessRole.runJob` set, so any path that reached the shared
/// `AppState` would trap and fail the exit test. Drives an engine built as `fire` builds one,
/// through its own executor: what a CLI turn dispatches through after an approval (plan note 6).
@MainActor
enum RunJobSkillScenario {
    static func run() async -> Bool {
        ProcessRole.set(.runJob)
        guard let store = try? ConversationStore.inMemory() else { return false }
        let state = RunJobCLI.makeState(store: store)
        // Built the way `RunJobCLI.fire` builds its engine (`RunJobCLI.swift:463`): a second engine
        // over the state, not `state.engine`.
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: []), protectionEnabled: false)
        let body = String(repeating: "A procedure step. ", count: 4)
        let skillFile = IrisPaths.default.skillsDir.appendingPathComponent("probe/SKILL.md")
        try? FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let calls: [(String, [String: JSONValue])] = [
            ("write_file", ["path": .string(skillFile.path),
                            "content": .string("---\nname: probe\ndescription: probe\n---\n\(body)")]),
            ("create_skill", ["name": .string("probe-two"), "description": .string("probe"), "body": .string(body)]),
        ]
        for (name, args) in calls {
            await engine.setSystemPrompt(text: "primed")
            let executor = await engine.executor
            let result = await executor.execute(name: name, args: args)
            guard result.hasPrefix("Successfully") else { return false }
            guard await engine.systemPrompt == nil else { return false }
        }
        withExtendedLifetime(state) {}
        return true
    }
}
