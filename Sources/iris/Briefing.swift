import Foundation

/// 5b §0.3: what Iris sees of background work, on its own turns only. Every field is one the
/// harness wrote: the turn-context block neutralises `<`, so nothing inside it can be marked
/// untrusted, and a run's outcome text (which can carry fetched words) would arrive with the
/// harness's authority. The model reads the words through `get_job_run`, which is guarded.
enum Briefing {
    static let heading = "Recent Activity"
    static let recentCap = 5

    static func section(failures: [JobRun], paused: [Job], recent: [JobRun]) -> TurnContext.Section? {
        var lines: [String] = paused.map { "- \(name($0.name)) · paused (job \(short($0.id)))" }
        lines += failures.map(line)
        let shown = Set(failures.map(\.id))
        lines += recent.filter { !shown.contains($0.id) }.prefix(recentCap).map(line)
        guard !lines.isEmpty else { return nil }
        return .init(heading: heading, body: lines.joined(separator: "\n"))
    }

    private static func line(_ run: JobRun) -> String {
        "- \(name(run.jobName)) · \(reason(run)) (run \(short(run.id)))"
    }

    private static func reason(_ run: JobRun) -> String {
        if run.status == .blockedOnApproval, let tool = run.blockedTool, isToolName(tool) {
            return "blocked: \(tool)"
        }
        return run.status.text
    }

    private static func isToolName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
    }

    /// One line, no role markers, no `<`, capped. A job's name is set by whoever created it.
    static func name(_ raw: String) -> String {
        var flat = PromptInjectionGuard.sanitizeUntrustedInput(raw)
            .components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "<", with: "")
        // `sanitizeUntrustedInput` only strips its exact role-prefix strings; a marker with
        // trailing whitespace before the colon (`system :`), or one sitting mid-line after other
        // text, can still survive. Strip the word-bounded form too, case-insensitively.
        if let re = try? NSRegularExpression(pattern: #"(?i)\b(system|assistant|user)\s*:"#) {
            let range = NSRange(flat.startIndex..., in: flat)
            flat = re.stringByReplacingMatches(in: flat, range: range, withTemplate: "")
        }
        flat = flat.trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(60))
    }

    private static func short(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }
}
