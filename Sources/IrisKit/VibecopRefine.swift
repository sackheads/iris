import Foundation

/// #1278: `/vibecop refine` proposes lines for a workspace's `.iris/vibecop.md` from what the person
/// actually approved there, computed by the app with no model call. Planner's rulings on dev-1's design:
/// the evidence is every conversation bound to the same workspace (by real path), last `callWindow`
/// calls, never a job run, a guest's, or one a guest, a peer or an unattended arrival reached (F1, F2);
/// only the person's own approvals count, never YOLO, auto-approve, the allowlist or Vibecop's (F3);
/// a command ever left unapproved is never proposed, and nothing proposes an escalation (F4). Each line is
/// one exact approved command, never a prefix (planner's ruling on dev-1's #1335 review).
enum VibecopRefine {
    static let callWindow = 200
    /// Approvals an exact command needs before it is proposed: one click is not a habit.
    static let minimumApprovals = 2
    /// A longer command is skipped rather than copied into the rules.
    static let maxCommandLength = 200

    struct Proposal: Equatable {
        let command: String
        let approvals: Int
        var line: String { "- Routine here, approved exactly as written: `\(command)` (approved \(approvals)×)" }
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

    /// Planner's ruling on dev-1's review: the exact command the person approved, never a prefix or a
    /// program, since no number of approvals of `rm -rf build` approves `rm`. And it is model-written text
    /// going into a guard-rules file, so it is copied only when it can't be read as anything but a command:
    /// one line, no backtick to close the code span early, no longer than `maxCommandLength`. Nor one that
    /// looks like it holds a credential (dev-2's review): `.iris/vibecop.md` is often committed, so a token in
    /// an approved `curl -H` would land in the repository. The same check Always Allow uses (#1140).
    static func inert(_ command: String) -> String? {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= maxCommandLength,
              !text.contains(where: { $0.isNewline || $0 == "`" }),
              // A hidden character (a right-to-left override, a zero-width space, a control) would let the
              // file say something other than what the person reads (dev-2's review; Always Allow's editor
              // refuses them too).
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .format
                  || $0.properties.generalCategory == .control }),
              !SecretLikeDetector.containsSecretLikeSubstring(text) else { return nil }
        return text
    }

    /// The lines to propose: each exact command the person approved at least `minimumApprovals` times, never
    /// one any call left unapproved, and none `existing` already names.
    static func proposals(_ calls: [(command: String, byPerson: Bool, approved: Bool)], existing: String) -> [Proposal] {
        var counts: [String: Int] = [:], excluded = Set<String>()
        for call in calls {
            let text = call.command.trimmingCharacters(in: .whitespaces)
            if !call.approved { excluded.insert(text); continue }
            if call.byPerson, let command = inert(text) { counts[command, default: 0] += 1 }
        }
        return counts.filter { $0.value >= minimumApprovals && !excluded.contains($0.key) && !existing.contains("`\($0.key)`") }
            .map { Proposal(command: $0.key, approvals: $0.value) }
            .sorted { $0.approvals != $1.approvals ? $0.approvals > $1.approvals : $0.command < $1.command }
    }

    /// `existing` with the lines appended, its own bytes untouched.
    static func appended(_ existing: String, _ proposals: [Proposal]) -> String {
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        return existing + separator + proposals.map(\.line).joined(separator: "\n") + "\n"
    }
}
