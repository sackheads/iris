import Testing
import Foundation
@testable import IrisKit

/// The grader's run_command is always sandboxed and its workspace is mounted read-write, so it may
/// only be given a workspace the graded conversation had bound. With none, it is pointed at the
/// process cwd (read with `read_file`) but nothing is mounted: that cwd is `/` for the app and
/// anything for a `--run-job` (#611).
@MainActor
@Suite("The grader mounts only a bound workspace (#611)", .timeLimit(.minutes(1)))
struct GraderNoMountTests {
    /// Records what the grader was set up with on its first call, then submits a verdict.
    private final class Recorder: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: (workspace: String??, prompt: String)?
        let app: AppState
        let criterionId: UUID
        init(app: AppState, criterionId: UUID) { self.app = app; self.criterionId = criterionId }
        var observed: (workspace: String??, prompt: String)? { lock.withLock { seen } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let app = self.app
            let workspace: String?? = await MainActor.run {
                app.conversations.first { $0.isSubagent }.map { $0.workspacePath }
            }
            let prompt = request.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
            lock.withLock { if seen == nil { seen = (workspace, prompt) } }
            let call = FunctionCall(name: "submit_evaluation", args: ["evaluations": .array([
                .object(["criterion_id": .string(criterionId.uuidString), "verdict": .string("met"),
                         "evidence": .string("seen")])
            ])], id: nil, thought_signature: nil, thoughtSignature: nil)
            let part = Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
        }
    }

    private func grade(workspace: String?) async throws -> (workspace: String??, prompt: String) {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.autoApproveTools = true
        let originId = app.createNewConversation(isBackground: false, select: false)
        let criterion = Criterion(text: "the thing exists", kind: .qualitative, check: nil)
        let client = Recorder(app: app, criterionId: criterion.id)
        _ = await GoalEvaluator.shared.evaluate(contract: GoalContract(objective: "obj", criteria: [criterion]),
                                                workspace: workspace, originatingConversationId: originId,
                                                app: app, client: client)
        return try #require(client.observed)
    }

    @Test("no bound workspace: the grader gets none, so nothing is mounted, and is told to read the cwd")
    func unboundMountsNothing() async throws {
        let seen = try await grade(workspace: nil)
        #expect(seen.workspace == .some(nil), "the grader's conversation must exist and have no workspace")
        #expect(seen.prompt.contains(FileManager.default.currentDirectoryPath))
        #expect(seen.prompt.contains("No workspace is bound"))
        #expect(!seen.prompt.contains("already execute there"))
    }

    @Test("a bound workspace is the grader's own, as before")
    func boundIsMounted() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-grader-\(UUID().uuidString)").path
        let seen = try await grade(workspace: dir)
        #expect(seen.workspace == .some(dir))
        #expect(seen.prompt.contains("already execute there"))
    }

    @Test("callers hand the evaluator the raw workspace: only it and the approval resolve the cwd fallback")
    func callersPassTheRawWorkspace() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/IrisKit")
        var callers: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("gradingDirectory(") && !line.contains("func gradingDirectory") {
                callers.append(file)
            }
        }
        #expect(callers.sorted() == ["AppState.swift", "GoalEvaluator.swift"], "\(callers)")
    }
}
