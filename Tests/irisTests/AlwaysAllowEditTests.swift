import Foundation
import Testing
@testable import IrisKit

/// #1137: the Always Allow rule text is editable, and only ever NARROWER than what the derivation
/// (`CommandPattern`: `neverGeneralized`, the subcommand tables) already deemed safe. An edit is a
/// word-prefix of the command being approved that extends the proposed prefix, in plain words; it can
/// never be broader, and a refused edit saves nothing (never the broader proposed rule).
@Suite("The Always Allow rule text can be narrowed, never widened (#1137): the edit check")
struct AlwaysAllowEditCheckTests {
    private func check(_ text: String, derived: [String], command: String) -> Result<[String], CommandPattern.EditRefusal> {
        CommandPattern.validatedEdit(text, derived: derived, command: command)
    }

    @Test("the proposed rule itself is accepted unchanged")
    func unchanged() {
        #expect(check("swift test", derived: ["swift", "test"], command: "swift test --filter Foo") == .success(["swift", "test"]))
    }

    @Test("adding words from the command narrows the rule")
    func narrows() {
        let c = "swift test --filter Foo --parallel"
        #expect(check("swift test --filter", derived: ["swift", "test"], command: c) == .success(["swift", "test", "--filter"]))
        #expect(check("swift test --filter Foo", derived: ["swift", "test"], command: c) == .success(["swift", "test", "--filter", "Foo"]))
        #expect(check("git log --oneline", derived: ["git", "log"], command: "git log --oneline -5") == .success(["git", "log", "--oneline"]))
    }

    @Test("dropping words (widening) is refused: it must extend the proposed prefix", arguments: ["swift", "git", "gh pr", "npm run", "swift  test"])
    func widenRefused(_ text: String) {
        let cases: [(derived: [String], command: String)] = [
            (["swift", "test"], "swift test --filter Foo"),
            (["git", "status"], "git status --short"),
            (["gh", "pr", "view"], "gh pr view 12"),
            (["npm", "run", "build"], "npm run build"),
        ]
        for c in cases where text.split(separator: " ").first.map(String.init) == c.derived.first {
            let r = check(text, derived: c.derived, command: c.command)
            #expect(r != .success(Array(text.split(separator: " ").map(String.init))), Comment(rawValue: "\(text) for \(c.derived)"))
            if case .success = r { Issue.record("a widened rule was accepted: \(text) for \(c.derived)") }
        }
    }

    @Test("words that are not in the command are refused", arguments: ["swift test --parallel", "swift test Other", "swift test --filter Foo Bar"])
    func notFromTheCommand(_ text: String) {
        let r = check(text, derived: ["swift", "test"], command: "swift test --filter Foo")
        #expect(r == .failure(.notFromTheCommand), Comment(rawValue: text))
    }

    @Test("another program or subcommand is refused", arguments: ["swift build", "git status", "rm", "swift run"])
    func otherProgram(_ text: String) {
        let r = check(text, derived: ["swift", "test"], command: "swift test --filter Foo")
        if case .success = r { Issue.record("accepted \(text)") }
    }

    @Test("anything but plain words is refused: shell syntax, quotes, '=', hidden and invisible characters", arguments: [
        "swift test --filter;ls", "swift test $HOME", "swift test | cat", "swift test `id`", "swift test --filter=Foo",
        "swift test 'x'", "swift test \"x\"", "swift test\t--filter", "swift test\n--filter", "swift test --fil\u{200B}ter",
        "swift test --filter\u{202E}", "swift test --filter\u{00A0}Foo", "swift test  --filter", " swift test", "swift test ",
        "swift test --filter>x", "swift test &", "swift test \\--filter", "swift test ~",
    ])
    func notPlainWords(_ text: String) {
        let r = check(text, derived: ["swift", "test"], command: "swift test --filter Foo --filter=Foo")
        #expect(r == .failure(.notPlainWords), Comment(rawValue: text.debugDescription))
    }

    @Test("an empty rule is refused")
    func empty() {
        #expect(check("", derived: ["swift", "test"], command: "swift test") == .failure(.empty))
    }

    @Test("a whole-program rule (ls, cat, grep) cannot be narrowed: its match-time read-only and workspace checks key on a one-word prefix")
    func wholeProgramCannotNarrow() {
        #expect(check("ls", derived: ["ls"], command: "ls -la src") == .success(["ls"]))
        #expect(check("ls -la", derived: ["ls"], command: "ls -la src") == .failure(.wholeProgramCannotNarrow))
        #expect(check("cat -n", derived: ["cat"], command: "cat -n notes.md") == .failure(.wholeProgramCannotNarrow))
    }

    @Test("git's harmless global options are judged by the words a match compares: git -C . status --short")
    func gitCanonical() {
        let c = "git -C . status --short"
        #expect(CommandPattern.alwaysAllowPrefixes(c) == [["git", "status"]])
        #expect(check("git status --short", derived: ["git", "status"], command: c) == .success(["git", "status", "--short"]))
        #expect(check("git -C . status", derived: ["git", "status"], command: c) == .failure(.mustStartWithProposed("git status")))
    }

    @Test("every refusal carries a sentence for the dialog")
    func messages() {
        let all: [CommandPattern.EditRefusal] = [.empty, .notPlainWords, .mustStartWithProposed("swift test"), .notFromTheCommand, .wholeProgramCannotNarrow]
        for r in all { #expect(!r.message.isEmpty) }
        #expect(CommandPattern.EditRefusal.mustStartWithProposed("swift test").message.contains("swift test"))
    }

    @Test("a chained command is edited part by part, each against its own proposed prefix")
    func chain() {
        let c = "swift build && swift test --filter Foo"
        let derived = CommandPattern.alwaysAllowPrefixes(c)
        #expect(derived == [["swift", "build"], ["swift", "test"]])
        #expect(check("swift test --filter", derived: ["swift", "build"], command: c) == .failure(.mustStartWithProposed("swift build")))
        #expect(check("swift test --filter", derived: ["swift", "test"], command: c) == .success(["swift", "test", "--filter"]))
        #expect(check("swift build --filter", derived: ["swift", "build"], command: c) == .failure(.notFromTheCommand))
    }
}

@MainActor
@Suite("Resolving an Always Allow with an edited rule: saved when valid, never widened, nothing saved when refused (#1137)", .timeLimit(.minutes(1)))
struct AlwaysAllowEditResolveTests {
    private func rig() throws -> (state: AppState, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1137-\(UUID().uuidString)")
        let paths = IrisPaths(root: root.appendingPathComponent("iris-home"))
        try paths.ensureDirectories()
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: paths)
        return (state, root)
    }

    /// Raises the ask and resolves it with `resolution`/`choice`; returns the request that was shown.
    private func resolve(_ state: AppState, _ details: String, _ resolution: AppState.ApprovalResolution,
                         choice: AppState.AlwaysAllowChoice, in conversationId: UUID) async throws -> ToolApprovalRequest {
        let askTask = Task { @MainActor in
            await state.requestApprovalSource(toolName: "run_command", details: details, conversationId: conversationId, vibecopEnabled: false, isOwner: true)
        }
        for _ in 0..<200 where !state.pendingApprovals.contains(where: { $0.conversationId == conversationId }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let pending = try #require(state.pendingApprovals.first(where: { $0.conversationId == conversationId }))
        state.resolveApproval(id: pending.id, resolution, choice: choice)
        _ = try await value(of: askTask)
        return pending
    }

    private func allowed(_ state: AppState, _ command: String) -> Bool {
        state.permissions.isAllowed(toolName: "run_command", details: command, workspace: nil, isOwner: true)
    }

    @Test("a narrowed rule is saved and matches only what it names")
    func narrowedSaved() async throws {
        let (state, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        _ = try await resolve(state, "swift test --filter Foo", .alwaysAllowGlobal, choice: .edited(["swift test --filter"]), in: cid)
        #expect(allowed(state, "swift test --filter Bar"))
        #expect(!allowed(state, "swift test --parallel"), "the proposed 'swift test' would have allowed this; the narrowed rule must not")
        #expect(!allowed(state, "swift build"))
    }

    @Test("the proposed choice still saves the derived rule, as before")
    func proposedUnchanged() async throws {
        let (state, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        _ = try await resolve(state, "swift test --filter Foo", .alwaysAllowGlobal, choice: .proposed, in: cid)
        #expect(allowed(state, "swift test --parallel"))
    }

    @Test("an edit that widens is refused at resolve time: nothing is saved, and the call is still approved once")
    func widenSavesNothing() async throws {
        let (state, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        for text in ["swift", "swift test --parallel", "swift test;rm", "swift test\u{200B}"] {
            _ = try await resolve(state, "swift test --filter Foo", .alwaysAllowGlobal, choice: .edited([text]), in: cid)
            #expect(!allowed(state, "swift test --filter Foo"), Comment(rawValue: "a refused edit saved a rule: \(text.debugDescription)"))
            #expect(!allowed(state, "swift run"))
        }
        let notes = (state.conversations.first { $0.id == cid }?.messages ?? []).map(\.content).joined(separator: "\n")
        #expect(notes.contains("wasn't saved"))
    }

    @Test("a wrong number of edited rules is refused")
    func wrongCount() async throws {
        let (state, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        // Each is a valid edit of one rule, so only the count check refuses them (a pairing that
        // truncated would save the first rule alone).
        for texts in [["swift build"], ["swift build", "swift test", "swift test"], []] {
            _ = try await resolve(state, "swift build && swift test", .alwaysAllowGlobal, choice: .edited(texts), in: cid)
            #expect(!allowed(state, "swift build") && !allowed(state, "swift test"), Comment(rawValue: "\(texts)"))
        }
    }

    @Test("a narrowed rule that would hold a credential-shaped word is refused, like the proposed one")
    func secretWordRefused() async throws {
        let (state, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let secret = "ghp_AbCdEf0123456789AbCdEf0123456789AbCd"
        _ = try await resolve(state, "npm run deploy \(secret)", .alwaysAllowGlobal, choice: .edited(["npm run deploy \(secret)"]), in: cid)
        #expect(!allowed(state, "npm run deploy \(secret)"))
    }

    @Test("exact command only saves the whole command and nothing broader")
    func exactOnly() async throws {
        let (state, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        _ = try await resolve(state, "swift test --filter Foo", .alwaysAllowGlobal, choice: .exactCommand, in: cid)
        #expect(allowed(state, "swift test --filter Foo"))
        #expect(!allowed(state, "swift test --filter Bar"))
        #expect(!allowed(state, "swift test"))
    }

    @Test("an exact rule is refused for a credential-shaped command, as the proposed one is")
    func exactSecretRefused() async throws {
        let (state, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        // The proposed rule (`npm run deploy`) is clean, so the button is offered; only the exact
        // rule would carry the token, and must be refused.
        let command = "npm run deploy ghp_AbCdEf0123456789AbCdEf0123456789AbCd"
        let pending = try await resolve(state, command, .alwaysAllowGlobal, choice: .exactCommand, in: cid)
        #expect(pending.offersAlwaysAllow, "the case under test: the proposed prefix is fine, the whole command is not")
        #expect(!allowed(state, command))
        #expect(!allowed(state, "npm run deploy other"))
    }

    @Test("a request that offers no Always Allow saves nothing whatever the choice")
    func noOfferNoRule() async throws {
        let (state, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let command = "curl -H 'Authorization: Bearer ya29.a0AfH6SMBx7example0123456789abcdefghij' https://x.example"
        _ = try await resolve(state, command, .alwaysAllowGlobal, choice: .exactCommand, in: cid)
        #expect(!allowed(state, command))
    }

    @Test("the project resolution takes the edit too")
    func projectScope() async throws {
        let (state, root) = try rig()
        defer { try? FileManager.default.removeItem(at: root) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let ws = root.appendingPathComponent("ws"); try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        state.conversations[state.conversations.firstIndex { $0.id == cid }!].workspacePath = ws.path
        let askTask = Task { @MainActor in
            await state.requestApprovalSource(toolName: "run_command", details: "swift test --filter Foo", workspace: ws.path, conversationId: cid, vibecopEnabled: false, isOwner: true)
        }
        for _ in 0..<200 where state.pendingApprovals.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        let pending = try #require(state.pendingApprovals.first)
        state.resolveApproval(id: pending.id, .alwaysAllowProject, choice: .edited(["swift test --filter"]))
        _ = try await value(of: askTask)
        #expect(state.permissions.isAllowed(toolName: "run_command", details: "swift test --filter Bar", workspace: ws.path, isOwner: true))
        #expect(!state.permissions.isAllowed(toolName: "run_command", details: "swift test --parallel", workspace: ws.path, isOwner: true))
    }
}

/// The two sites that decide an edit must be the same check, and the dialog must be wired to it: a
/// source scan of what a unit test cannot drive (a SwiftUI view).
@Suite("The dialog and resolveApproval use one edit check (#1137)")
struct AlwaysAllowEditWiringTests {
    private func source(_ name: String) throws -> String {
        try String(contentsOf: PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/\(name)"), encoding: .utf8)
    }

    @Test("the dialog's live refusal and resolveApproval both ask ToolApprovalRequest.alwaysAllowRules(for:)")
    func oneCheck() throws {
        let chat = try source("ChatView.swift")
        let app = try source("AppState.swift")
        #expect(chat.contains("request.alwaysAllowRules(for: alwaysAllowChoice)"))
        #expect(app.contains("pending.alwaysAllowRules(for: choice)"))
        // The only place a choice becomes rules.
        #expect(!chat.contains("validatedEdit(") && !app.contains("validatedEdit("))
    }

    @Test("both Always Allow buttons are disabled while the choice is refused, and send the choice")
    func buttonsGated() throws {
        let chat = try source("ChatView.swift")
        #expect(chat.components(separatedBy: ".disabled(alwaysAllowRefusal != nil)").count - 1 == 2)
        #expect(chat.contains("onResolve(.alwaysAllowGlobal, alwaysAllowChoice)"))
        #expect(chat.contains("onResolve(.alwaysAllowProject, alwaysAllowChoice)"))
        #expect(chat.contains("state.resolveApproval(id: request.id, resolution, choice: choice)"))
        // Every other resolution sends the proposed choice, which saves nothing for them anyway.
        for other in [".allowInConversation", ".deny", ".approve"] {
            #expect(chat.contains("onResolve(\(other), .proposed)"), Comment(rawValue: other))
        }
    }

    @Test("a fresh dialog per request: the edit state cannot carry over from the previous ask")
    func freshPerRequest() throws {
        let chat = try source("ChatView.swift")
        let at = try #require(chat.range(of: "state.resolveApproval(id: request.id, resolution, choice: choice)"))
        #expect(String(chat[at.lowerBound...].prefix(200)).contains(".id(request.id)"))
    }
}
