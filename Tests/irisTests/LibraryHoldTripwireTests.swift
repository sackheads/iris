import Testing
import Foundation
@testable import IrisKit

/// #1295, deferred by the planner's ruling: `ContextHolds.heldWritePath` leaves `memory/library/`
/// and `memory/artifacts/` out, on purpose. A pinned Iris writes notes there all the time and
/// nearly every working conversation is tainted, so holding them would turn every reflection and
/// every no-workspace plan into an approval card (#814). That is safe only while nothing puts
/// their content into a prompt. These two tripwires fail the day something does, unless the same
/// change adds the folder to `heldWritePath`.
private enum LibraryHoldTripwire {
    static func message(_ what: String) -> Comment {
        let text = "\(what) -- #1295: library/artifacts content now reaches a prompt, so a tainted conversation's "
            + "write there becomes standing context unreviewed. Add the folder to `ContextHolds.heldWritePath` "
            + "in the same change (see #1295 for the options and the prompt cost), then this passes."
        return Comment(rawValue: text)
    }

    /// Whether the hold already covers a file under `dir`, so the tripwire stands down for it.
    static func held(_ dir: URL, paths: IrisPaths) -> Bool {
        ContextHolds.heldWritePath(dir.appendingPathComponent("probe.md").path, cwd: nil, paths: paths, irisPaths: paths)
    }
}

/// The live half: real turns on an isolated home with a marker in each library and artifacts
/// file, reading every request the model would have been sent.
@MainActor
@Suite("library/artifacts content never reaches a prompt while unheld (#1295)", .serialized, .timeLimit(.minutes(1)))
struct LibraryHoldTripwireTurnTests {
    @Test("an owner turn and a reflection turn carry no library or artifacts text")
    func noLibraryOrArtifactsTextInAnyRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1295-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        let fm = FileManager.default
        var markers: [(dir: URL, file: URL, marker: String)] = []
        for dir in [paths.libraryDir, paths.artifactsDir] {
            // The spellings a future reader would most plausibly pick up: an index, a nested note,
            // and the AGENTS.md/SKILL.md names other loaders already look for.
            for relative in ["README.md", "notes/decision.md", "AGENTS.md", "proj/specs/SKILL.md"] {
                let file = dir.appendingPathComponent(relative)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let marker = "TRIPWIRE-1295-\(UUID().uuidString)"
                try "# Note\n\(marker)\n".write(to: file, atomically: true, encoding: .utf8)
                markers.append((dir, file, marker))
            }
        }
        for file in [paths.userMd, paths.soulMd, paths.memoryMd] {
            try "owner's own text".write(to: file, atomically: true, encoding: .utf8)
        }

        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.autoApproveTools = true
        let conversation = state.createNewConversation(title: "tripwire", select: true)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: client, retryDelays: [],
                                streamResponses: false, protectionEnabled: false, sessionPeerCount: 0,
                                memory: MemoryManager(paths: paths), accessProfileStore: AccessProfileStore(paths: paths))
        state.installEngine(engine)

        await engine.processInput("hello", source: "UI", conversationId: conversation)
        // The reflection prompt is the one that names the library, so it is the likeliest turn
        // for a future change to start reading it into.
        await engine.processInput(AppState.reflectionPrompt, source: "UI", conversationId: conversation)

        let requests = client.requests
        #expect(requests.count >= 2, "both turns must reach the model, or this checked nothing")
        let sent = try requests.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")
        for (dir, file, marker) in markers where !LibraryHoldTripwire.held(dir, paths: paths) {
            #expect(!sent.contains(marker), LibraryHoldTripwire.message("\(file.path) was sent to the model"))
        }
    }
}

/// The structural half: a reader of the two folders anywhere in the product. The live half only
/// sees the turns it drives; a new route (a job, a goal kickoff, a profile prompt) reading the
/// library would get past it. The only code that may name the folders today creates them
/// (`IrisPaths.ensureDirectories`), seeds shipped files into them (`ShippedSkills`), or migrates
/// an old layout (`IrisMigrator`).
@Suite("no product code reads library/artifacts while unheld (#1295)")
struct LibraryHoldTripwireSourceScanTests {
    static let allowedFiles: Set<String> = ["IrisPaths.swift", "ShippedSkills.swift", "IrisMigrator.swift"]

    @Test("libraryDir and artifactsDir appear only where the folders are made, seeded or migrated")
    func onlyAllowedFilesNameTheFolders() throws {
        let sources = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "the scan must see the product sources, or it checked nothing")
        let paths = IrisPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("iris-1295-scan"))
        let watched = [("libraryDir", paths.libraryDir), ("artifactsDir", paths.artifactsDir)]
            .filter { !LibraryHoldTripwire.held($0.1, paths: paths) }
        for file in files where !Self.allowedFiles.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (name, _) in watched where text.contains(name) {
                Issue.record(LibraryHoldTripwire.message("\(file.lastPathComponent) names `\(name)`"))
            }
        }
    }
}
