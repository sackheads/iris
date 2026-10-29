import CryptoKit
import Foundation

/// #813: a write that would become standing prompt context (SOUL, USER, memory.md, facts, skills,
/// rules), made by a conversation that has read untrusted output (`hasUntrustedToolOutput`), is
/// kept here instead of applied, until the person approves or rejects it. Held means not written:
/// SOUL.md, the fact store, the skills folder and rules/ are untouched until approval, so the
/// prompt builders need no filter and cannot leak a pending item.
struct PendingContextWrite: Codable, Equatable, Sendable, Identifiable {
    enum State: String, Codable, Sendable { case pending, applied, rejected, stale, failed }

    var id: UUID
    /// The conversation that made the call: a subagent's own, for a delegate.
    var conversationId: UUID
    /// The session it worked for when held (`delegationRoot`), where the chip shows it. Nil means
    /// `conversationId` itself.
    var rootConversationId: UUID?
    var toolName: String
    var args: [String: JSONValue]
    /// The workspace the call resolved relative paths against, for a held `write_file`.
    var workspacePath: String?
    /// The file the write lands on, resolved; nil for a fact.
    var targetPath: String?
    /// The target's sha256 when held; nil when it did not exist then (and for a fact). Approving
    /// over a target that has changed since asks first: a full overwrite would drop the edit.
    var targetSha256: String?
    /// What the chip and the sheet show: kind and target, then the content's first line.
    var firstLine: String
    var createdAt: Date
    var state: State
    /// #817's read-out: the turn that held it, whether it was the pinned Iris then, and when it
    /// was decided. Optional, so a row written without them still reads.
    var turnId: UUID?
    var isPinnedIris: Bool?
    var decidedAt: Date?
    /// What applying it returned: why it went stale or failed, too.
    var outcome: String?
}

enum ContextHolds {
    /// The tools whose every call writes standing context. `write_file` is held only when its
    /// target is one of those files (`heldWritePath`); every other write under ~/.iris is not
    /// (#813 scope: a pinned Iris writes notes there all the time, #814).
    static let heldTools: Set<String> = [
        "update_soul", "update_user_profile", "update_memory",
        "save_fact", "manage_fact",
        "create_skill", "update_skill", "delete_skill",
    ]

    /// Set only while an approved item is applied, so the dispatcher runs it instead of holding
    /// it again. A task-local: nothing the model sends can set it.
    @TaskLocal static var applying = false

    static let heldResultPrefix = "Saved for the person to review"

    /// Whether an approved item's handler reports that it wrote. The handlers share no failure
    /// prefix ("Error…", "Fact not saved:", "Skill … not found.", "Not run:", a hook's block), but
    /// each success is one known shape, so anything else counts as not applied. An AfterTool hook
    /// that rewrites a success reads as failed: the loud side.
    static func reportsApplied(_ tool: String, result: String) -> Bool {
        switch tool {
        case "write_file", "create_skill", "update_skill", "delete_skill":
            return result.hasPrefix("Successfully ")
        case "update_soul": return result.hasPrefix("Soul updated.")
        case "update_user_profile": return result == "User profile updated."
        case "update_memory": return result == "Memory updated."
        case "save_fact": return result.hasPrefix("Fact saved to fact store as ") || result.hasPrefix("Already stored as ")
        case "manage_fact":
            guard result.hasPrefix("Fact "), !result.contains(" unchanged: ") else { return false }
            return [" is now retracted.", " is now superseded by ", " is active again.", " rated "].contains { result.contains($0) }
        default: return false
        }
    }

    /// What the model reads when the hold cannot be checked (the app's state is gone): the write
    /// is refused, never run, since a conversation the app doesn't know is not clean.
    static func uncheckedResult(_ tool: String) -> String {
        "Not run: `\(tool)` changes what Iris remembers, and this conversation's history couldn't be checked; nothing was written."
    }

    /// What the model reads instead of the tool's result.
    static func heldResult(_ item: PendingContextWrite) -> String {
        "\(heldResultPrefix): this conversation has read untrusted output, so \(item.firstLine) takes effect only "
            + "when they approve it. Don't make the call again."
    }

    /// `paths` is where the engine's memory tools write SOUL, USER and memory.md (its
    /// `MemoryManager`); skills and rules are read and written under `irisPaths`, the home's.
    static func shouldHold(_ name: String, args: [String: JSONValue], cwd: String?, paths: IrisPaths,
                           irisPaths: IrisPaths = .default) -> Bool {
        if heldTools.contains(name) { return true }
        guard name == "write_file", let path = args["path"]?.stringValue else { return false }
        return heldWritePath(path, cwd: cwd, paths: paths, irisPaths: irisPaths)
    }

    /// SOUL.md, USER.md, memory.md, or anything under the skills folder or rules/, compared by
    /// real path so a link or another spelling of the same file is the same file.
    static func heldWritePath(_ path: String, cwd: String?, paths: IrisPaths, irisPaths: IrisPaths = .default) -> Bool {
        let target = IrisPaths.realPath(ToolExecutor.resolvePath(path, cwd: cwd))
        for file in [paths.soulMd, paths.userMd, paths.memoryMd, irisPaths.soulMd, irisPaths.userMd, irisPaths.memoryMd]
        where IrisPaths.samePath(target, IrisPaths.realPath(file.path)) {
            return true
        }
        return [paths.skillsDir, paths.rulesDir, irisPaths.skillsDir, irisPaths.rulesDir].contains { dir in
            let root = IrisPaths.realPath(dir.path)
            return target.lowercased().hasPrefix(root.lowercased() + "/")
        }
    }

    /// The file a held call would write, or nil for a fact.
    static func targetPath(_ name: String, args: [String: JSONValue], cwd: String?, paths: IrisPaths,
                           irisPaths: IrisPaths = .default) -> String? {
        switch name {
        case "update_soul": return paths.soulMd.path
        case "update_user_profile": return paths.userMd.path
        case "update_memory": return paths.memoryMd.path
        case "create_skill", "update_skill", "delete_skill":
            guard let skill = args["name"]?.stringValue,
                  let folder = ToolExecutor.skillFolder(named: skill, paths: irisPaths) else { return nil }
            return folder.appendingPathComponent("SKILL.md").path
        case "write_file":
            guard let path = args["path"]?.stringValue else { return nil }
            return IrisPaths.realPath(ToolExecutor.resolvePath(path, cwd: cwd))
        default: return nil
        }
    }

    static func sha256(ofFileAt path: String?) -> String? {
        guard let path, let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the target is no longer what it was when the item was held.
    static func targetChanged(_ item: PendingContextWrite) -> Bool {
        guard item.targetPath != nil else { return false }
        return sha256(ofFileAt: item.targetPath) != item.targetSha256
    }

    /// One line a glance can approve: what kind of change, to what, then its first line of text.
    static func firstLine(_ name: String, args: [String: JSONValue], targetPath: String?, paths: IrisPaths) -> String {
        func lead(_ key: String) -> String {
            let text = args[key]?.stringValue ?? ""
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count > 120 ? String(trimmed.prefix(119)) + "…" : trimmed
        }
        let skill = args["name"]?.stringValue ?? "?"
        switch name {
        case "update_soul": return "a SOUL.md rewrite (\"\(lead("content"))\")"
        case "update_user_profile": return "a USER.md rewrite (\"\(lead("content"))\")"
        case "update_memory": return "a memory.md rewrite (\"\(lead("content"))\")"
        case "save_fact": return "a new fact (\"\(lead("content"))\")"
        case "manage_fact":
            let action = args["action"]?.stringValue ?? "?"
            return "\(action) on fact [\(args["fact_id"]?.stringValue ?? "?")]"
        case "create_skill": return "a new skill '\(skill)' (\"\(lead("description"))\")"
        case "update_skill": return "a change to skill '\(skill)'"
        case "delete_skill": return "deleting skill '\(skill)'"
        default:
            let shown = targetPath.map { path -> String in
                let root = IrisPaths.realPath(paths.root.path)
                return path.hasPrefix(root + "/") ? "~/.iris/" + path.dropFirst(root.count + 1) : path
            } ?? "a file"
            return "a write to \(shown) (\"\(lead("content"))\")"
        }
    }
}

/// #817: `iris --context-holds-report [--days N]`, the week's read-out of how often the hold
/// asks and how fast the person answers. Read-only on the store; never the Keychain or the
/// shared settings (#805).
enum ContextHoldsReport {
    struct Row: Sendable, Equatable {
        var turnId: UUID?
        var toolName: String
        var state: PendingContextWrite.State
        var isPinnedIris: Bool
        var createdAt: Date
        var decidedAt: Date?
    }

    static func render(_ rows: [Row], days: Int, now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        var out = ["Context holds, last \(days) day\(days == 1 ? "" : "s") (pinned Iris | other conversations)"]
        for back in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let inDay = rows.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
            out.append("")
            out.append(f.string(from: day))
            for (label, pinned) in [("pinned Iris", true), ("other", false)] {
                out.append("  \(label): " + line(inDay.filter { $0.isPinnedIris == pinned }))
            }
        }
        return out.joined(separator: "\n")
    }

    static func line(_ rows: [Row]) -> String {
        let turns = Set(rows.map { $0.turnId?.uuidString ?? "none" }).count
        let kinds = Dictionary(grouping: rows, by: \.toolName).map { "\($0.key) \($0.value.count)" }.sorted()
        func count(_ s: PendingContextWrite.State) -> Int { rows.filter { $0.state == s }.count }
        let waits = rows.compactMap { r in r.decidedAt.map { $0.timeIntervalSince(r.createdAt) } }.sorted()
        let median: String
        if waits.isEmpty {
            median = "-"
        } else {
            let mid = waits.count / 2
            let m = waits.count % 2 == 1 ? waits[mid] : (waits[mid - 1] + waits[mid]) / 2
            median = duration(m)
        }
        return "turns with the chip \(rows.isEmpty ? 0 : turns), held \(rows.count)"
            + (kinds.isEmpty ? "" : " (\(kinds.joined(separator: ", ")))")
            + ", approved \(count(.applied)), rejected \(count(.rejected)), stale \(count(.stale)), failed \(count(.failed)), pending \(count(.pending))"
            + ", median to decide \(median)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min" }
        return String(format: "%.1f h", seconds / 3600)
    }
}

/// `iris --context-holds-report [--days N]` (#817).
enum ContextHoldsReportCLI {
    struct UsageError: Error, Equatable { let message: String }

    static let usage = "usage: iris --context-holds-report [--days N]   (N from 1 to 365; default 7)"

    /// nil when the flag is absent; the day count, or why the arguments are wrong.
    static func parse(_ args: [String]) -> Result<Int, UsageError>? {
        guard let i = args.firstIndex(of: "--context-holds-report") else { return nil }
        let rest = Array(args[(i + 1)...])
        if rest.isEmpty { return .success(7) }
        guard rest.count == 2, rest[0] == "--days", let n = Int(rest[1]), (1...365).contains(n) else {
            return .failure(UsageError(message: "--days takes a whole number from 1 to 365"))
        }
        return .success(n)
    }

    /// Prints the report for this build's home. Exit 0 with zeros when there is nothing to read.
    static func run(days: Int, paths: IrisPaths = .standard, now: Date = Date()) -> Int32 {
        do {
            let rows = try ConversationStore.readPendingWrites(at: paths.conversationsDB).map(row)
            print(ContextHoldsReport.render(rows, days: days, now: now))
            return 0
        } catch {
            FileHandle.standardError.write(Data("iris --context-holds-report: could not read \(paths.conversationsDB.path): \(error)\n".utf8))
            return 1
        }
    }

    static func row(_ item: PendingContextWrite) -> ContextHoldsReport.Row {
        .init(turnId: item.turnId, toolName: item.toolName, state: item.state, isPinnedIris: item.isPinnedIris == true,
              createdAt: item.createdAt, decidedAt: item.decidedAt)
    }
}
