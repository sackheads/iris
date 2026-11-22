import Foundation

/// #1278: `/vibecop refine` proposes lines for a workspace's `.iris/vibecop.md` from what the person
/// actually approved there, computed by the app with no model call. Planner's rulings on dev-1's design:
/// the evidence is every conversation bound to the same workspace (by real path), last `callWindow`
/// calls, never a job run, a guest's, or one a guest, a peer or an unattended arrival reached (F1, F2);
/// only the person's own approvals count, never YOLO, auto-approve, the allowlist or Vibecop's (F3);
/// a shape ever left unapproved is never proposed, and nothing proposes an escalation (F4).
enum VibecopRefine {
    static let callWindow = 200
    /// Approvals a shape needs before it is proposed: one click is not a habit.
    static let minimumApprovals = 3

    struct Proposal: Equatable {
        let shape: String
        let approvals: Int
        var line: String { "- Routine here: `\(shape)` (approved \(approvals)×)" }
    }

    /// The conversations whose calls count for `workspace`: bound to it by real path, and none a job run,
    /// a guest's session, or one another party's text reached.
    static func evidence(_ conversations: [Conversation], workspace: String) -> [Conversation] {
        let target = IrisPaths.realPath(IrisEngine.expandTilde(workspace))
        return conversations.filter { c in
            guard let ws = c.workspacePath, !ws.isEmpty,
                  IrisPaths.samePath(IrisPaths.realPath(IrisEngine.expandTilde(ws)), target) else { return false }
            return !c.isBackground && !c.isGuest && !c.hasGuestInput && !c.hasPeerInput && !c.hasUnattendedInput
        }
        .sorted { ($0.lastTouchedAt ?? .distantPast) > ($1.lastTouchedAt ?? .distantPast) }
    }

    /// The newest `callWindow` host commands across `conversations` (newest conversation first, newest call
    /// first within it), each with whether the person's own click let it run.
    static func recentCommands(_ conversations: [Conversation]) -> [(command: String, byPerson: Bool, approved: Bool)] {
        var calls: [(String, Bool, Bool)] = []
        for c in conversations {
            for m in c.messages.reversed() where m.role == .system {
                guard let call = ToolCallParser.parse(m.content), call.name == "run_command",
                      let command = call.command else { continue }
                // A pill with no approval did not run: denied, refused, or never decided (F4's "denied").
                calls.append((command, m.approval?.layer == .person, m.approval != nil))
                if calls.count == callWindow { return calls }
            }
        }
        return calls
    }

    /// `program subcommand` for a simple command (`swift test`, `git status`), or the program alone;
    /// nil for an assignment or an empty one.
    static func shape(_ words: [String]) -> String? {
        guard let program = words.first, !program.contains("=") else { return nil }
        if words.count > 1, words[1].range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil {
            return "\(program) \(words[1])"
        }
        return program
    }

    /// The lines to propose: person-approved single-command shapes, at least `minimumApprovals` times,
    /// never one any command left unapproved or a compound command touched, and none `existing` names.
    static func proposals(_ calls: [(command: String, byPerson: Bool, approved: Bool)], existing: String) -> [Proposal] {
        var counts: [String: Int] = [:], excluded = Set<String>()
        for call in calls {
            let segments = simpleCommands(call.command)
            let shapes = segments.compactMap(shape)
            // Anything left unapproved counts against every shape in it; a compound command never counts for one.
            if !call.approved { excluded.formUnion(shapes); continue }
            guard segments.count == 1, let one = shapes.first else { continue }
            if call.byPerson { counts[one, default: 0] += 1 }
        }
        return counts.filter { $0.value >= minimumApprovals && !excluded.contains($0.key) && !existing.contains("`\($0.key)`") }
            .map { Proposal(shape: $0.key, approvals: $0.value) }
            .sorted { $0.approvals != $1.approvals ? $0.approvals > $1.approvals : $0.shape < $1.shape }
    }

    /// The command's simple commands, split at `;`, `&`, `|`, parentheses, a backtick or a line break, quoted
    /// or not. Over-splitting only fails safe here: a command then reads as compound (never counted), and a
    /// denied one excludes more shapes.
    static func simpleCommands(_ command: String) -> [[String]] {
        command.components(separatedBy: CharacterSet(charactersIn: ";&|()`\n")).map(HostRunFiles.words).filter { !$0.isEmpty }
    }

    /// `existing` with the lines appended, its own bytes untouched.
    static func appended(_ existing: String, _ proposals: [Proposal]) -> String {
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        return existing + separator + proposals.map(\.line).joined(separator: "\n") + "\n"
    }
}
