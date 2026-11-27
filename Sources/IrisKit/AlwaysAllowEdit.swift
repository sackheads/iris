import Foundation

/// #1137: what an Always Allow click saves for an edited rule. The one place the dialog's choice
/// becomes rules, used by the dialog (live, to show why a typed rule is refused) and again by
/// `AppState.resolveApproval`, so a dialog that skipped its own check still cannot save a broader
/// rule: the same function decides in both.
struct AlwaysAllowRefusal: Error, Equatable {
    let message: String
}

extension ToolApprovalRequest {
    static let leavesWorkspaceMessage = "This command leaves the workspace, so Always allow can't cover it. Set the conversation's workspace to that folder instead."
    static let oneOffChainMessage = "This chain has a command Always allow can't generalise, so it's Allow once only."
    static let exactCompoundMessage = "A chain or a cd is saved as its commands' rules, never as its exact text."

    /// #1428: a click never saves a rule that wouldn't match the very call it came from (a `cd` to a sibling worktree
    /// saved a `swift build` prefix that asked again every time). An exact rule always matches its own call.
    func alwaysAllowRules(for choice: AppState.AlwaysAllowChoice) -> Result<[PermissionRule], AlwaysAllowRefusal> {
        let result = derivedAlwaysAllowRules(for: choice)
        guard case .success(let rules) = result, toolName == "run_command", rules.contains(where: \.isPrefix) else { return result }
        let prefixes = rules.filter(\.isPrefix).map { $0.details.split(separator: " ").map(String.init) }
        guard CommandPattern.matchedPrefixes(details, prefixes: prefixes, workspace: workspace) != nil else {
            return .failure(AlwaysAllowRefusal(message: Self.leavesWorkspaceMessage))
        }
        return result
    }

    private func derivedAlwaysAllowRules(for choice: AppState.AlwaysAllowChoice) -> Result<[PermissionRule], AlwaysAllowRefusal> {
        guard offersAlwaysAllow else { return .success([]) }
        switch choice {
        case .proposed:
            return .success(alwaysAllowRules)
        case .exactCommand:
            guard toolName == "run_command" else { return .success(alwaysAllowRules) }
            // #1428: a chain or a `cd` is a one-off; its exact text would only collect cruft.
            if CommandPattern.isCompound(details) {
                return .failure(AlwaysAllowRefusal(message: Self.exactCompoundMessage))
            }
            // An exact rule carries the whole command, so the credential check the proposed prefix
            // got (#1140) applies to the whole text.
            if SecretLikeDetector.containsSecretLikeSubstring(details) {
                return .failure(AlwaysAllowRefusal(message: Self.secretDetectedMessage))
            }
            return .success([PermissionRule(toolName: toolName, details: details)])
        case .edited(let texts):
            guard toolName == "run_command", !alwaysAllowRules.isEmpty, alwaysAllowRules.allSatisfy(\.isPrefix),
                  texts.count == alwaysAllowRules.count else {
                return .failure(AlwaysAllowRefusal(message: "This rule can't be edited."))
            }
            var rules: [PermissionRule] = []
            for (rule, text) in zip(alwaysAllowRules, texts) {
                let derived = rule.details.split(separator: " ").map(String.init)
                switch CommandPattern.validatedEdit(text, derived: derived, command: details) {
                case .failure(let why):
                    return .failure(AlwaysAllowRefusal(message: why.message))
                case .success(let words):
                    let edited = PermissionRule(toolName: toolName, details: words.joined(separator: " "), match: .prefix)
                    if SecretLikeDetector.containsSecretLikeSubstring(edited.details) {
                        return .failure(AlwaysAllowRefusal(message: Self.secretDetectedMessage))
                    }
                    rules.append(edited)
                }
            }
            return .success(rules)
        }
    }
}
