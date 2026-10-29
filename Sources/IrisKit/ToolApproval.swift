import Foundation

/// What let a tool call run, kept on its pill's message (#599): which layer said yes and why, so
/// "why did this run without asking?" can be answered from the transcript afterwards. Its own
/// small type rather than `AppState.ApprovalSource`, so a case added to that enum later cannot
/// make a stored message unreadable, and a rule edited or removed later does not change what the
/// record says: the rule's text is copied in when it matched.
struct ToolApproval: Codable, Equatable, Sendable {
    enum Layer: String, Codable, Sendable {
        case person, autoApprove, allowlist, grant, graderCheck, vibecop, vibecopRestricted
        /// #812: an outbound tool the person exempted, for the conversation or for the job.
        case exemption
        /// The tool has no approval step: nobody was asked, and nothing had to say yes.
        case ungated
        /// Read from a newer build: shown as an approval it cannot name.
        case unknown
    }

    var layer: Layer
    /// Vibecop's reason, the matched rule's details, the granted mount, or the grader's kind.
    var detail: String?
    /// For `allowlist`: `irisHome`, `global` or `project`.
    var scope: String?
    /// The command or path a BeforeTool hook rewrote the call to, before its approval (#647): what
    /// was approved and what ran, in full.
    var hookRewrite: String?

    init(layer: Layer, detail: String? = nil, scope: String? = nil) {
        self.layer = layer
        self.detail = detail
        self.scope = scope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layer = (try? c.decodeIfPresent(Layer.self, forKey: .layer)) ?? .unknown
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        hookRewrite = try c.decodeIfPresent(String.self, forKey: .hookRewrite)
    }

    static let ungated = ToolApproval(layer: .ungated)

    init(_ source: AppState.ApprovalSource) {
        switch source {
        case .person:
            self.init(layer: .person)
        case .autoApprove(let vibecop):
            self.init(layer: .autoApprove, detail: vibecop)
        case .allowlist(let match):
            self.init(layer: .allowlist, detail: match.rule.map { "\($0.toolName) \($0.details)" }, scope: match.scope.rawValue)
        case .grant(let mount):
            self.init(layer: .grant, detail: mount)
        case .graderCheck(let kind):
            self.init(layer: .graderCheck, detail: kind.rawValue)
        case .vibecop(let reason):
            self.init(layer: .vibecop, detail: reason)
        case .vibecopRestricted(_, let reason):
            self.init(layer: .vibecopRestricted, detail: reason)
        }
    }

    /// Vibecop's reason is a model's text: shown plain, and only so much of it.
    static let reasonLimit = 200

    private var shownDetail: String? {
        guard let detail, !detail.isEmpty else { return nil }
        let flat = detail.replacingOccurrences(of: "\n", with: " ")
        return flat.count > Self.reasonLimit ? String(flat.prefix(Self.reasonLimit)) + "…" : flat
    }

    /// What the pill, its tooltip and an export say. nil for a person's approval of a call no hook
    /// rewrote: the dialog they answered is its record.
    var line: String? {
        let rewrite = hookRewrite.map { "Your BeforeTool hook changed this call before it was approved; it ran: \($0)" }
        guard let base = layerLine else { return rewrite }
        return rewrite.map { base + " " + $0 } ?? base
    }

    private var layerLine: String? {
        switch layer {
        case .person:
            return nil
        case .ungated:
            return "No approval needed for this tool (nobody was asked)."
        case .exemption:
            return detail == "job"
                ? "Exempted for this job when you approved it (or with /jobs exempt): it sends without asking."
                : "You allowed this tool in this conversation: it sends without asking."
        case .autoApprove:
            return "Auto-approve is on (headless run)." + (shownDetail.map { " Vibecop's verdict, not used: \($0)" } ?? "")
        case .allowlist:
            let place = switch scope {
            case "irisHome": "Iris's own folder"
            case "project": "this project's rules"
            default: "your global rules"
            }
            if let rule = shownDetail { return "Allowed by a rule in \(place): \(rule)" }
            return "Allowed: it is inside \(place)."
        case .grant:
            if let mount = shownDetail { return "Allowed by this job run's sandbox grant: \(mount)" }
            return "Allowed by this job run's sandbox grant: a command in the sandbox."
        case .graderCheck:
            return detail == AppState.GraderApproval.read.rawValue
                ? "A read inside the workspace you approved when you locked the goal."
                : "A check you approved when you locked the goal."
        case .vibecop:
            return "Approved by Vibecop" + (shownDetail.map { ": \($0)" } ?? ".")
        case .vibecopRestricted:
            return "Approved by Vibecop as a read-only command, run with a restricted shell"
                + (shownDetail.map { ": \($0)" } ?? ".")
        case .unknown:
            return "Approved without asking (by a layer this version of Iris does not know)."
        }
    }
}
