import Foundation

/// What the job-creating tools need from the app: the ledger to write into. Nothing else —
/// storing a job is the whole of registering a watch now, because the ledger's `onJobsChanged`
/// hook is what tells the watch layer to catch up (#187 deliverable 4, §7), and an engine that
/// never called `start()` has no watch layer for a second handle to reach.
struct JobTools: Sendable {
    let ledger: JobLedger
}

struct ToolExecutor {
    static let shared = ToolExecutor()

    /// How `register_directory_watcher` and `schedule_job` reach the jobs table. The executor is a
    /// value type built long before the conversation store opens, so the engine hands it a closure
    /// that resolves the ledger on demand rather than one at construction — an engine that never
    /// calls `start()` (a subagent, an evaluator, a scenario run) still gets a working tool. nil —
    /// the case for `ToolExecutor.shared` and for the plugin auth runner's throwaway executor —
    /// means the tool declines instead of registering a watch nothing runs.
    var jobToolsProvider: (@Sendable () async -> JobTools?)?

    /// Where Iris's own directory and the user's home are, for `register_directory_watcher`'s
    /// refusals (`WatchRoot.refusal`). nil — the case in the app — means the real ones, resolved
    /// when the tool runs rather than when the executor is built, so a headless run that installs
    /// a volatile copy after this value exists is still refused on the copy. A test sets both so
    /// that nothing it does resolves through `~/.iris`.
    var irisPaths: IrisPaths?
    var homeDirectory: String?

    /// How the sandboxed branch of `run_command` reaches the container session. Injectable so a
    /// test can assert what that branch forwards — the command, the workspace, and the deadline —
    /// without a `container` binary, a daemon or a VM. nil, the case everywhere in the app, means
    /// the one `SandboxSessionManager` the process shares.
    var sandboxSession: (@Sendable (_ command: String, _ conversationId: UUID, _ workspace: String?, _ timeoutSeconds: Int) async -> String)?

    /// Merges the captured login-shell PATH (`loginPath`) ahead of `base`'s own `PATH`, so host
    /// `run_command` invocations see pyenv/nvm/Homebrew shims that only `.zprofile`/`.zshrc` set up
    /// (#69) without spawning a login shell per command (which prints profile banners and can have
    /// side effects). Order is preserved and duplicates are removed, keeping the first occurrence.
    /// If `loginPath` is empty, `base` is returned unchanged.
    static func commandEnvironment(base: [String: String], loginPath: [String]) -> [String: String] {
        guard !loginPath.isEmpty else { return base }
        let basePath = base["PATH"]?.components(separatedBy: ":").filter { !$0.isEmpty } ?? []
        var seen: Set<String> = []
        let merged = (loginPath + basePath).filter { seen.insert($0).inserted }
        var env = base
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    /// `workspaceToolsEnabled` defaults to "a Google refresh token is configured". Without one every
    /// Google Tasks / Workspace call fails, so the ten declarations were pure prompt weight (#133).
    /// Injectable so tests never mutate `ConfigManager.shared`.
    func getTools(workspaceToolsEnabled: Bool = !ConfigManager.shared.googleRefreshToken.isEmpty) async -> [FunctionDeclaration] {
        var tools = [
            FunctionDeclaration(
            name: "run_command",
            description: "Executes a shell command. Use this for standard operations.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "command": Schema(type: "STRING", description: "The command to run in bash/zsh"),
                    "timeout_seconds": Schema(type: "INTEGER", description: "Optional timeout in seconds (default 600, max 3600). Set higher for long-running operations like docker builds or package installs.")
                ],
                required: ["command"]
            )
        ),
        FunctionDeclaration(
            name: "read_file",
            description: "Reads the contents of a file.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "path": Schema(type: "STRING", description: "Absolute, tilde (~), or workspace-relative path to the file. A relative path resolves against the conversation's bound workspace, not the app's directory.")
                ],
                required: ["path"]
            )
        ),
        FunctionDeclaration(
            name: "write_file",
            description: "Writes content to a file, overwriting existing content.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "path": Schema(type: "STRING", description: "Absolute, tilde (~), or workspace-relative path to the file. A relative path resolves against the conversation's bound workspace, not the app's directory."),
                    "content": Schema(type: "STRING", description: "The content to write")
                ],
                required: ["path", "content"]
            )
        ),
        FunctionDeclaration(
            name: "register_directory_watcher",
            description: Self.watchDescription,
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "path": Schema(type: "STRING", description: "Absolute, tilde (~), or workspace-relative path to watch. A relative path resolves against the conversation's bound workspace, not the app's directory."),
                    "instructions": Schema(type: "STRING", description: "The instructions to execute when a file is modified"),
                    "quiet_window_seconds": Schema(type: "INTEGER", description: "1 to 300; outside is clamped"),
                    "ignore": Schema(type: "ARRAY", description: "glob patterns relative to the path, e.g. `*.log`, `build/`", items: Schema(type: "STRING")),
                    "overlap": Schema(type: "STRING", description: "`queue` or `skip`")
                ],
                required: ["path", "instructions"]
            )
        ),
        FunctionDeclaration(
            name: "search_web",
            description: "Search the web using DuckDuckGo. Returns a JSON array of results with title, url, and snippet.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "query": Schema(type: "STRING", description: "The search query")
                ],
                required: ["query"]
            )
        ),
        FunctionDeclaration(
            name: "create_skill",
            description: "Create a reusable procedural skill in the local skill library (~/.iris/memory/skills/<name>/SKILL.md).",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "name": Schema(type: "STRING", description: "Short kebab-case skill identifier (e.g. gke-deployment-debug)"),
                    "description": Schema(type: "STRING", description: "High-signal summary of what this skill does and when to trigger it"),
                    "body": Schema(type: "STRING", description: "Full Markdown body containing numbered steps, exact commands, pitfalls, and verification steps")
                ],
                required: ["name", "description", "body"]
            )
        ),
        FunctionDeclaration(
            name: "update_skill",
            description: "Update an existing skill in the local skill library (~/.iris/memory/skills/<name>/SKILL.md).",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "name": Schema(type: "STRING", description: "Skill identifier to update"),
                    "description": Schema(type: "STRING", description: "Updated description (optional if unchanged)"),
                    "body": Schema(type: "STRING", description: "Updated Markdown body or additional procedures (optional if description updated)")
                ],
                required: ["name"]
            )
        ),
        FunctionDeclaration(
            name: "delete_skill",
            description: "Delete a skill from the local skill library (~/.iris/memory/skills/<name>/SKILL.md).",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "name": Schema(type: "STRING", description: "The skill identifier to delete")
                ],
                required: ["name"]
            )
        )
        ]
        
        if workspaceToolsEnabled {
            let tasksTools = await GoogleTasksManager.shared.getTools()
            tools.append(contentsOf: tasksTools)

            let workspaceTools = await GoogleWorkspaceManager.shared.getTools()
            tools.append(contentsOf: workspaceTools)
        }
        
        let mcpTools = await MCPManager.shared.getGeminiTools()
        tools.append(contentsOf: mcpTools)
        return tools
    }
    
    func execute(name: String, args: [String: JSONValue], cwd: String? = nil, conversationId: UUID? = nil, useSandbox: Bool = false) async -> String {
        switch name {
        case "run_command":
            guard let command = args["command"]?.stringValue else { return "Error: Missing command" }
            let rawTimeout: Double = switch args["timeout_seconds"] {
            case .int(let i): Double(i)
            case .double(let d): d
            default: 600
            }
            let timeoutSeconds = min(max(rawTimeout, 10), 3600)
            return await runCommand(command, cwd: cwd, conversationId: conversationId, useSandbox: useSandbox, timeoutSeconds: timeoutSeconds)
        case "read_file":
            guard let path = args["path"]?.stringValue else { return "Error: Missing path" }
            return await readFile(path, cwd: cwd)
        case "write_file":
            guard let path = args["path"]?.stringValue, let content = args["content"]?.stringValue else { return "Error: Missing path or content" }
            return await writeFile(path, content: content, cwd: cwd)
        case "register_directory_watcher":
            switch RegisterWatcherArguments.parse(args) {
            case .failure(let message): return message.text
            case .success(let parsed):
                return await registerWatcher(parsed, resolved: Self.resolvePath(parsed.path, cwd: cwd), conversationId: conversationId)
            }
        case "search_web":
            guard let query = args["query"]?.stringValue else { return "Error: Missing query" }
            return await searchWeb(query: query)
        case "create_skill":
            guard let name = args["name"]?.stringValue,
                  let description = args["description"]?.stringValue,
                  let body = args["body"]?.stringValue ?? args["content"]?.stringValue else {
                return "Error: Missing name, description, or body for create_skill"
            }
            return await createSkill(name: name, description: description, body: body)
        case "update_skill":
            guard let name = args["name"]?.stringValue else {
                return "Error: Missing name for update_skill"
            }
            let description = args["description"]?.stringValue
            let body = args["body"]?.stringValue ?? args["content"]?.stringValue
            return await updateSkill(name: name, description: description, body: body)
        case "delete_skill":
            guard let name = args["name"]?.stringValue else { return "Error: Missing name for delete_skill" }
            return await deleteSkill(name: name)
        case let n where n.hasPrefix("google_tasks_"):
            return await GoogleTasksManager.shared.execute(name: name, args: args)
        case let n where n.hasPrefix("google_calendar_") || n.hasPrefix("google_docs_") || n.hasPrefix("google_drive_") || n.hasPrefix("google_sheets_") || n.hasPrefix("gmail_"):
            return await GoogleWorkspaceManager.shared.execute(name: name, args: args)
        default:
            if name.contains("___") {
                return await MCPManager.shared.callTool(name: name, args: args)
            }
            return "Error: Unknown tool \(name)"
        }
    }
    
    /// The declaration, two sentences (invariant 6): what the tool does and that its own runs'
    /// writes are safe — only those (R-D4-1), so the sentence must not say "Iris's". The built-in ignore set, the ×10 ceiling and the never-concurrent rule are said once,
    /// in the result the model reads after calling it, not paid for on every turn.
    static let watchDescription = "Watch a directory for file changes and run your instructions in the background once it has been quiet for a few seconds (default 3). The watch ignores its runs' own file-tool writes, so a run can safely write into the folder."

    static let allIgnoredRefusal = "that ignore list would ignore every change; drop the pattern or watch a narrower path"

    /// Stores a `.fsEvent` job for the directory (#187 deliverable 4, spec §5). The job is named
    /// after the directory being watched rather than the instructions, because that is what a user
    /// scanning the jobs list is looking for.
    ///
    /// A watch belongs to the conversation that registered it. Re-registering the same directory
    /// from that conversation updates its job in place — the model re-states a standing instruction
    /// often (a new turn, a rephrasing) — and an argument it does not re-state keeps its stored
    /// value; being asked for again is also being asked to be on, so `enabled` and `pausedReason`
    /// are reset whatever was said. Another conversation registering the same directory gets a
    /// watch of its own, suffixed, and is told how many now cover the folder: two standing orders
    /// on one folder are two orders, and silently rewriting someone else's is the worse surprise.
    /// The match is by canonical path, case-insensitively (R-D4-8) — the same rule
    /// `WatcherManager` keys its streams by, and the reason the cost of being wrong (two genuinely
    /// distinct directories on a case-sensitive volume sharing one watch) is accepted there too.
    private func registerWatcher(_ parsed: RegisterWatcherArguments, resolved: String, conversationId: UUID?) async -> String {
        guard let tools = await jobToolsProvider?() else { return "Jobs are not available yet." }
        // The canonical spelling is what is stored and what event paths are matched against
        // (`WatchRoot`); a path that is not a directory has no canonical form worth storing.
        var isDirectory: ObjCBool = false
        guard let path = WatchRoot.canonical(resolved),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "That path does not exist or is not a directory: \(resolved)"
        }
        if let refusal = WatchRoot.refusal(for: path, paths: irisPaths ?? .default,
                                           home: homeDirectory ?? NSHomeDirectory()) {
            return "Not watching \(path): \(refusal)."
        }
        if let ignore = parsed.ignore, WatchGlob.ignoresEveryProbe(ignore) {
            return "Not watching \(path): \(Self.allIgnoredRefusal)."
        }
        let window = parsed.quietWindowSeconds.map(FSWatch.clampQuietWindow)
        let clamped = window != nil && window != parsed.quietWindowSeconds
        do {
            let jobs = try tools.ledger.jobs()
            let key = path.lowercased()
            let watching = jobs.filter { job in
                guard case .fsEvent(let watch) = job.trigger else { return false }
                return watch.path.lowercased() == key
            }
            var job: Job
            let opening: String
            if var existing = watching.first(where: { $0.createdInConversationId == conversationId }),
               case .fsEvent(var watch) = existing.trigger {
                existing.prompt = parsed.instructions
                if let window { watch.quietWindowSeconds = window }
                if let ignore = parsed.ignore { watch.ignore = ignore }
                existing.trigger = .fsEvent(watch)
                if let overlap = parsed.overlap { existing.policy.overlap = overlap }
                existing.enabled = true
                existing.pausedReason = nil
                job = existing
                opening = "updated your watch `\(job.name)`"
            } else {
                job = Job(
                    name: ScheduleJobArguments.uniqueName(
                        Job.slug(from: URL(fileURLWithPath: path).lastPathComponent),
                        existing: Set(jobs.map(\.name))),
                    prompt: parsed.instructions,
                    trigger: .fsEvent(FSWatch(path: path, quietWindowSeconds: window ?? FSWatch.defaultQuietWindowSeconds,
                                              ignore: parsed.ignore ?? [])),
                    createdInConversationId: conversationId,
                    // A watch never runs concurrently with itself; by default a save that lands
                    // mid-run is queued, not dropped.
                    policy: JobPolicy(overlap: parsed.overlap ?? .queue))
                let others = watching.map { "`\($0.name)`" }
                let named = others.count <= 2 ? others.joined(separator: " and ")
                    : others.dropLast().joined(separator: ", ") + " and " + others[others.count - 1]
                opening = "created `\(job.name)`" + (others.isEmpty ? "" :
                    "; \(named) \(others.count == 1 ? "belongs to another conversation" : "belong to other conversations")"
                    + " — this folder now has \(others.count + 1) watches, each of which runs on every change")
            }
            // The write is the registration: in the app, `onJobsChanged` syncs the coordinator
            // and the stream set within the same second. An engine that never started (a subagent,
            // an evaluator, a scenario run) has no hook installed and no watcher running, so there
            // is nothing here to reload — the job is stored and the next launch picks it up.
            try tools.ledger.upsert(job)
            guard case .fsEvent(let stored) = job.trigger else { return "Could not save the watcher job." }
            var sentences = ["Watching \(path): \(opening)."]
            var runs = "It runs once the folder has been quiet for \(stored.quietWindowSeconds) s"
                + " (\(stored.ceilingSeconds) s when changes never stop) and never alongside its own previous run;"
                + " it ignores .git/, .DS_Store, node_modules/, *~, *.swp, *.swx, .#*, 4913, *.tmp and Foundation's atomic-write temp files"
            if !stored.ignore.isEmpty {
                runs += ", plus your \(stored.ignore.count) pattern\(stored.ignore.count == 1 ? "" : "s")"
            }
            sentences.append(runs + ".")
            if clamped, let window { sentences.append("The window was clamped to \(window) s.") }
            return sentences.joined(separator: " ")
        } catch {
            return "Could not save the watcher job."
        }
    }

    private func runCommand(_ command: String, cwd: String?, conversationId: UUID? = nil, useSandbox: Bool = false, timeoutSeconds: Double = 600) async -> String {
        if useSandbox, let conversationId {
            let expandedCwd = cwd.map { ($0 as NSString).expandingTildeInPath }
            // The same deadline the host branch enforces, in seconds — the container runtime kills
            // the command on it. It used to be dropped here, which left a sandboxed command with
            // no bound at all while the model believed it had set one.
            let deadline = Int(timeoutSeconds)
            if let sandboxSession {
                return await sandboxSession(command, conversationId, expandedCwd, deadline)
            }
            guard SandboxingManager.shared.isContainerInstalled else {
                return "Error: sandboxing is on but the container runtime isn't installed. Open Iris Settings → Sandboxing to install it, or turn sandboxing off."
            }
            return await SandboxSessionManager.shared.run(command: command, conversationId: conversationId,
                                                          workspace: expandedCwd, timeoutSeconds: deadline)
        }
        // Hoist process/pipes so the cancellation handler can capture them.
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        if useSandbox {
            guard let containerPath = SandboxingManager.shared.containerBinaryPath else {
                return "Error: sandboxing is on but the container runtime isn't installed. Open Iris Settings → Sandboxing to install it, or turn sandboxing off."
            }
            process.executableURL = URL(fileURLWithPath: containerPath)
            var containerArgs = ["run", "--rm", ConfigManager.shared.sandboxImage, "bash", "-c", command]
            if let cwd = cwd {
                let expandedPath = (cwd as NSString).expandingTildeInPath
                // `-v`, where the session path uses `--mount` (see `ContainerMount`). The CLI
                // lowers both to the same virtiofs bind; this one is the ephemeral no-conversation
                // path and is left as it was rather than changed for symmetry alone.
                containerArgs.insert(contentsOf: ["-v", "\(expandedPath):\(expandedPath)", "--workdir", expandedPath], at: 2)
            }
            process.arguments = containerArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            if let cwd = cwd {
                process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
            }
            process.environment = Self.commandEnvironment(base: ProcessInfo.processInfo.environment, loginPath: BinaryResolver.defaultSearchDirs())
        }
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            return try await withTimeout(seconds: timeoutSeconds) {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        process.terminationHandler = { proc in
                            // Kill direct children before reading pipes. Child processes that
                            // inherited these pipe file descriptors (e.g. a CLI plugin spawned
                            // by the main process) keep the write end open after the parent dies,
                            // causing readDataToEndOfFile() to block until they exit too.
                            let killer = Process()
                            killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                            killer.arguments = ["-9", "-P", String(proc.processIdentifier)]
                            killer.standardOutput = FileHandle.nullDevice
                            killer.standardError = FileHandle.nullDevice
                            try? killer.run()
                            killer.waitUntilExit()

                            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                            var result = ""
                            if let outputStr = String(data: outputData, encoding: .utf8), !outputStr.isEmpty {
                                result += outputStr
                            }
                            if let errorStr = String(data: errorData, encoding: .utf8), !errorStr.isEmpty {
                                result += "\nStderr: " + errorStr
                            }

                            // When sandboxing is on and the `container` runtime failed to start the command
                            // (not provisioned: services down or no VM kernel), it emits opaque errors like
                            // "unauthorized request". Rewrite those to an actionable message so the model and
                            // user aren't left guessing (which previously led to confabulated "auth wall"
                            // explanations).
                            if useSandbox, proc.terminationStatus != 0,
                               let hint = Self.sandboxSetupHint(for: result) {
                                continuation.resume(returning: hint)
                                return
                            }

                            continuation.resume(returning: result.isEmpty ? "Success" : result)
                        }

                        do {
                            try process.run()
                        } catch {
                            continuation.resume(returning: "Error executing command: \(error.localizedDescription)")
                        }
                    }
                } onCancel: {
                    process.terminate()
                }
            }
        } catch {
            return Self.commandTimedOutMessage(seconds: timeoutSeconds)
        }
    }

    /// What a command that outlived its deadline reports. One sentence for both routes: a command
    /// killed in the container reads exactly like one killed on the host, because which side of
    /// the VM boundary ran out of time is not the model's problem.
    static func commandTimedOutMessage(seconds: Double) -> String {
        "Error: command timed out after \(Int(seconds)) seconds"
    }
    
    /// Maps a failed sandboxed `container run` output to an actionable setup message, or nil if
    /// the output does not look like a container-runtime-not-ready error. The matched phrases are
    /// emitted by Apple's `container` CLI when its services aren't started or no VM kernel is
    /// installed — not by ordinary command output.
    static func sandboxSetupHint(for output: String) -> String? {
        let lower = output.lowercased()
        let notReadySignatures = [
            "unauthorized request",
            "plugins are unavailable",
            "no default kernel",
            "container system start",
            "failed to read user input",
        ]
        guard notReadySignatures.contains(where: { lower.contains($0) }) else { return nil }
        return """
        Error: the sandbox container runtime is installed but not ready. This usually means its \
        background services aren't started or the default VM kernel isn't installed.

        To fix, run in a terminal and accept the default kernel install when prompted:
            container system start

        Or disable sandboxing in Iris Settings to run commands directly on the host.

        (original runtime error: \(output.trimmingCharacters(in: .whitespacesAndNewlines)))
        """
    }

    /// Resolves a tool-supplied path against the bound workspace. Absolute paths and `~` are honored
    /// as-is; a RELATIVE path is joined onto `cwd` (the conversation's workspace) so it lands in the
    /// workspace, not the iris process's own working directory. Without a workspace, relative paths
    /// keep their prior (process-cwd) behavior. This mirrors how `run_command` already uses `cwd`
    /// and closes the gap where relative `write_file` paths clobbered the iris source tree (#68).
    static func resolvePath(_ path: String, cwd: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !(expanded as NSString).isAbsolutePath, let cwd = cwd else { return expanded }
        let base = (cwd as NSString).expandingTildeInPath
        return URL(fileURLWithPath: base).appendingPathComponent(expanded).path
    }

    private func readFile(_ path: String, cwd: String? = nil) async -> String {
        let expandedPath = Self.resolvePath(path, cwd: cwd)
        return await Task.detached {
            do {
                return try String(contentsOfFile: expandedPath, encoding: .utf8)
            } catch {
                return "Error reading file: \(error.localizedDescription)"
            }
        }.value
    }

    private func writeFile(_ path: String, content: String, cwd: String? = nil) async -> String {
        let expandedPath = Self.resolvePath(path, cwd: cwd)
        return await Task.detached {
            do {
                try content.write(toFile: expandedPath, atomically: true, encoding: .utf8)
                return "Successfully wrote to \(expandedPath)"
            } catch {
                return "Error writing file: \(error.localizedDescription)"
            }
        }.value
    }
    
    private func searchWeb(query: String) async -> String {
        let script = """
import urllib.request
import urllib.parse
from html.parser import HTMLParser
import sys
import json

class DDGParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.results = []
        self.current_title = ""
        self.current_url = ""
        self.current_snippet = ""
        self.capture_type = None

    def handle_starttag(self, tag, attrs):
        attr_dict = dict(attrs)
        if tag == "a" and "result-link" in attr_dict.get("class", ""):
            self.current_url = attr_dict.get("href", "")
            self.capture_type = "title"
        if tag == "td" and "result-snippet" in attr_dict.get("class", ""):
            self.capture_type = "snippet"

    def handle_data(self, data):
        if self.capture_type == "title":
            self.current_title += data
        elif self.capture_type == "snippet":
            self.current_snippet += data

    def handle_endtag(self, tag):
        if tag == "a" and self.capture_type == "title":
            self.capture_type = None
        elif tag == "td" and self.capture_type == "snippet":
            self.capture_type = None
            if self.current_title and self.current_url and self.current_snippet:
                self.results.append({
                    "title": self.current_title.strip(),
                    "url": self.current_url.strip(),
                    "snippet": self.current_snippet.strip()
                })
            self.current_title = ""
            self.current_url = ""
            self.current_snippet = ""

query = sys.argv[1]
data = urllib.parse.urlencode({"q": query}).encode("utf-8")
req = urllib.request.Request("https://lite.duckduckgo.com/lite/", data=data, headers={"User-Agent": "Mozilla/5.0"})
try:
    html = urllib.request.urlopen(req).read().decode("utf-8")
    parser = DDGParser()
    parser.feed(html)
    print(json.dumps(parser.results[:10], indent=2))
except Exception as e:
    print(json.dumps({"error": str(e)}))
"""
        let home = FileManager.default.homeDirectoryForCurrentUser
        let irisDir = home.appendingPathComponent(".iris")
        try? FileManager.default.createDirectory(at: irisDir, withIntermediateDirectories: true)
        let scriptURL = irisDir.appendingPathComponent("search_web.py")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", scriptURL.path, query]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? "Error decoding output"
        } catch {
            return "Error executing search script: \(error)"
        }
    }

    /// Where a skill of this name lives: the one spelling of the folder, for the three tools that
    /// write it and for the dispatcher, which has to work out what a skill call wrote from its
    /// arguments (the tools take no path, so there is nothing else to read; #187 §4).
    ///
    /// The name is slugged the same way for all three — lowercased, trimmed, spaces and
    /// underscores to dashes. `deleteSkill` used to lowercase and trim but not replace, so
    /// `delete_skill` with the name `my skill` looked for a folder `create_skill` had never made.
    static func skillFolder(named name: String, paths: IrisPaths = .default) -> URL {
        let cleanName = name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        return paths.skillsDir.appendingPathComponent(cleanName)
    }

    func createSkill(name: String, description: String, body: String, paths: IrisPaths = .default) async -> String {
        let skillFolder = Self.skillFolder(named: name, paths: paths)
        let cleanName = skillFolder.lastPathComponent
        let skillFile = skillFolder.appendingPathComponent("SKILL.md")
        
        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: Date())
        
        let okfContent = """
        ---
        name: \(cleanName)
        description: \(description)
        type: skill
        timestamp: \(timestamp)
        ---

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: skillFolder, withIntermediateDirectories: true)
            try okfContent.write(to: skillFile, atomically: true, encoding: .utf8)
            await AppState.shared.invalidateEnginePrompt()
            return "Successfully saved skill '\(cleanName)' to \(skillFile.path). System prompt cache updated."
        } catch {
            return "Error saving skill '\(cleanName)': \(error.localizedDescription)"
        }
    }

    func updateSkill(name: String, description: String?, body: String?, paths: IrisPaths = .default) async -> String {
        let skillFolder = Self.skillFolder(named: name, paths: paths)
        let cleanName = skillFolder.lastPathComponent
        let skillFile = skillFolder.appendingPathComponent("SKILL.md")
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: skillFile.path) else {
            let desc = description ?? "No description provided."
            let content = body ?? "No procedure steps provided."
            return await createSkill(name: cleanName, description: desc, body: content, paths: paths)
        }
        
        var existingDesc = "No description provided."
        var existingBody = ""
        
        if let existingContent = try? String(contentsOf: skillFile, encoding: .utf8) {
            let lines = existingContent.components(separatedBy: .newlines)
            var inFrontmatter = false
            var bodyLines: [String] = []
            
            for line in lines {
                if line == "---" {
                    inFrontmatter = !inFrontmatter
                    continue
                }
                if inFrontmatter {
                    if line.starts(with: "description:") {
                        existingDesc = String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                    }
                } else {
                    bodyLines.append(line)
                }
            }
            existingBody = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        let finalDesc = description ?? existingDesc
        let finalBody = body ?? existingBody
        
        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: Date())
        
        let okfContent = """
        ---
        name: \(cleanName)
        description: \(finalDesc)
        type: skill
        timestamp: \(timestamp)
        ---

        \(finalBody)
        """
        
        do {
            try okfContent.write(to: skillFile, atomically: true, encoding: .utf8)
            await AppState.shared.invalidateEnginePrompt()
            return "Successfully updated skill '\(cleanName)' in \(skillFile.path). System prompt cache updated."
        } catch {
            return "Error updating skill '\(cleanName)': \(error.localizedDescription)"
        }
    }

    func deleteSkill(name: String, paths: IrisPaths = .default) async -> String {
        let skillFolder = Self.skillFolder(named: name, paths: paths)
        let cleanName = skillFolder.lastPathComponent
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: skillFolder.path) else {
            return "Skill '\(cleanName)' not found."
        }
        do {
            try fileManager.removeItem(at: skillFolder)
            await AppState.shared.invalidateEnginePrompt()
            return "Successfully deleted skill '\(cleanName)'. System prompt cache updated."
        } catch {
            return "Error deleting skill '\(cleanName)': \(error.localizedDescription)"
        }
    }
}
