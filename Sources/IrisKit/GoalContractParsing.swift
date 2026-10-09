import Foundation

enum GoalContractParsing {
    static func contract(from args: [String: JSONValue]) -> GoalContract? {
        guard let objective = args["objective"]?.stringValue, !objective.isEmpty else { return nil }

        func strings(_ key: String) -> [String] {
            guard case .array(let arr)? = args[key] else { return [] }
            var result: [String] = []
            for item in arr {
                if case .string(let s) = item {
                    result.append(s)
                } else {
                    print("[iris] GoalContract parse: non-string element in '\(key)' array ignored")
                }
            }
            return result
        }

        var criteria: [Criterion] = []
        var order: [String] = []                 // milestone titles in first-appearance order
        var groups: [String: [UUID]] = [:]
        if case .array(let arr)? = args["criteria"] {
            for item in arr {
                guard case .object(let obj) = item, let text = obj["text"]?.stringValue else { continue }
                let rawKind = obj["kind"]?.stringValue ?? ""
                let kind = CriterionKind(rawValue: rawKind)
                if kind == nil, !rawKind.isEmpty {
                    print("[iris] GoalContract parse: unknown criterion kind '\(rawKind)', falling back to qualitative")
                }
                let resolvedKind = kind ?? .qualitative
                let check = resolvedKind == .executable ? obj["check"]?.stringValue : nil
                let criterion = Criterion(text: text, kind: resolvedKind, check: check)
                criteria.append(criterion)
                if let label = obj["milestone"]?.stringValue,
                   !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if groups[label] == nil { order.append(label) }
                    groups[label, default: []].append(criterion.id)
                }
            }
        }
        let milestones = order.map { Milestone(title: $0, criterionIds: groups[$0] ?? []) }

        // Trimmed, and empty means absent — an empty string would resolve differently from nil.
        let workspace = args["workspace"]?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        return GoalContract(objective: objective,
                            criteria: criteria,
                            outOfScope: strings("out_of_scope"),
                            stopBefore: strings("stop_before"),
                            assumptions: strings("assumptions"),
                            milestones: milestones,
                            state: .draft,
                            workspace: workspace)
    }
}

extension GoalContractParsing {
    /// Slice B3 — builds the bounded unit contract a parent hands a delegated subagent. The
    /// parent's `task` becomes the objective and `criteria` are parsed by the very same code path
    /// as `propose_goal_contract`, so invalid/empty entries are skipped identically.
    ///
    /// Returns nil when no usable criterion survives parsing: no contract means no grade, which is
    /// the unchanged B2 delegation path rather than an error.
    static func unitContract(task: String, criteriaJSON: JSONValue?) -> GoalContract? {
        guard let criteriaJSON,
              let parsed = contract(from: ["objective": .string(task), "criteria": criteriaJSON]),
              !parsed.criteria.isEmpty
        else { return nil }

        // Strip any milestone grouping the parent supplied. B3 deliberately does not wire the B1
        // ladder to delegation, and a ladder here would actively strand the run: the oracle would
        // tell the subagent to call `reach_checkpoint`, which is gated to the main principal, so
        // it would loop to its iteration cap instead of finishing.
        var unit = parsed
        unit.milestones = []
        unit.currentMilestone = 0
        // Locked, not draft: this is a definition of done the subagent is held to, not one it may
        // edit. It is also what persists into `SubagentResult.unitContract`, where `.draft` would
        // misrepresent what the run was measured against.
        unit.lock()
        return unit
    }
}


private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
