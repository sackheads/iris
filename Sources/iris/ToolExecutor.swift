import Foundation

/// What the job-creating tools need from the app: the ledger to write into, and the watcher
/// manager to reload once the write lands. They travel together because a watch job that is
/// stored but not reloaded does nothing until the next launch.
struct JobTools: Sendable {
    let ledger: JobLedger
    let watchers: WatcherManager
    /// What one watch fire does. Carried alongside the ledger because a `WatcherManager` gets both
    /// or neither: `setCallback` has a single caller, `IrisEngine.start()`, three lines from its
    /// `configure(ledger:)`. A manager adopted by an engine that never started would otherwise run
    /// a live FSEvents stream whose fires go nowhere. No default — every caller has to say.
    let watcherCallback: @Sendable (Job, [String]) async -> Void

    init(ledger: JobLedger, watchers: WatcherManager,
         watcherCallback: @escaping @Sendable (Job, [String]) async -> Void) {
        self.ledger = ledger
        self.watchers = watchers
        self.watcherCallback = watcherCallback
    }
}

struct ToolExecutor {
    static let shared = ToolExecutor()

    /// How `register_directory_watcher` reaches the jobs table and the watchers running off it.
    /// The executor is a value type built long before the conversation store opens, so the engine
    /// hands it a closure that resolves both on demand rather than a ledger at construction — an
    /// engine that never calls `start()` (a subagent, an evaluator, a scenario run) still gets a
    /// working tool. nil — the case for `ToolExecutor.shared` and for the plugin auth runner's
    /// throwaway executor — means the tool declines instead of registering a watch nothing runs.
    var jobToolsProvider: (@Sendable () async -> JobTools?)?

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
            description: "Watch a directory for file changes. This creates a job that persists across restarts and runs your instructions in the background whenever files under the path are modified. Each run happens in a hidden conversation of its own and reports one card into the pinned 'Iris Activity' conversation rather than interrupting this one; nobody is there to approve a gated tool, so a run whose work needs approval stops and says so. Use this when the user asks you to monitor a folder.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "path": Schema(type: "STRING", description: "Absolute, tilde (~), or workspace-relative path to watch. A relative path resolves against the conversation's bound workspace, not the app's directory."),
                    "instructions": Schema(type: "STRING", description: "The instructions to execute when a file is modified")
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
            guard let path = args["path"]?.stringValue, let instructions = args["instructions"]?.stringValue else { return "Error: Missing path or instructions" }
            return await registerWatcher(path: Self.resolvePath(path, cwd: cwd), instructions: instructions, conversationId: conversationId)
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
    
    /// Stores a `.fsEvent` job for `path` and restarts the watch set. The job is named after the
    /// directory being watched rather than the instructions, because that is what a user scanning
    /// the jobs list is looking for.
    ///
    /// Re-registering a path already watched rewrites that job's instructions and destination in
    /// place rather than adding a second one: the model re-states a standing instruction often (a
    /// new turn, a rephrasing), and two jobs on one directory means two watchers and two turns per
    /// save.
    private func registerWatcher(path rawPath: String, instructions: String, conversationId: UUID?) async -> String {
        guard let tools = await jobToolsProvider?() else { return "Jobs are not available yet." }
        // The canonical spelling is what gets stored and what event paths are matched against; a
        // path that is not there yet falls back to the best resolution available so it still
        // round-trips, rather than being stored under two spellings.
        let path = WatchRoot.canonical(rawPath) ?? IrisPaths.canonicalPath(rawPath)
        do {
            let jobs = try tools.ledger.jobs()
            var job: Job
            let watchesPath: (Job) -> Bool = { job in
                guard case .fsEvent(let watch) = job.trigger else { return false }
                return watch.path == path
            }
            if var existing = jobs.first(where: watchesPath) {
                // An explicit "watch this" is also a request for it to be on, and for the fires
                // to land where it was asked for — the latest registration wins the destination
                // the same way it wins the instructions.
                existing.prompt = instructions
                existing.enabled = true
                existing.createdInConversationId = conversationId
                job = existing
            } else {
                job = Job(
                    name: ScheduleJobArguments.uniqueName(
                        Job.slug(from: URL(fileURLWithPath: path).lastPathComponent),
                        existing: Set(jobs.map(\.name))),
                    prompt: instructions,
                    trigger: .fsEvent(FSWatch(path: path, quietWindowSeconds: 3)),
                    createdInConversationId: conversationId,
                    // A watch never runs concurrently with itself: a save that lands mid-run is
                    // queued, not dropped. An existing job keeps whatever policy it was given.
                    policy: JobPolicy(overlap: .queue))
            }
            try tools.ledger.upsert(job)
            await tools.watchers.reload(adoptingIfUnconfigured: tools.ledger, callback: tools.watcherCallback)
            return "Watching \(path) as job '\(job.name)'. It runs in the background when files change; you will be notified automatically."
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

    func createSkill(name: String, description: String, body: String, paths: IrisPaths = .default) async -> String {
        let cleanName = name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        
        let skillFolder = paths.skillsDir.appendingPathComponent(cleanName)
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
        let cleanName = name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        
        let skillFolder = paths.skillsDir.appendingPathComponent(cleanName)
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
        let cleanName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let skillFolder = paths.skillsDir.appendingPathComponent(cleanName)
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
