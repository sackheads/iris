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

    /// Whether a `mutating` watch would get the VM its commands need (`SandboxPolicy.mutatingJobCanRun`).
    /// nil, the case in the app, asks the real policy when the tool runs; a test sets `{ true }`.
    var mutatingJobsAvailable: (@Sendable () -> Bool)?

    /// The watch breaker figure the registration answer quotes (#283), injectable so a test asserts
    /// against a number it chose rather than whatever this machine's Settings say. Reading
    /// `ConfigManager.shared` is allowed — invariant 7 forbids *mutating* it — but a test that
    /// depended on its value would pass or fail by the developer's settings.
    var watchBreakerProvider: (@Sendable () -> Int)?
    static let watchProfileNeedsSandbox = "A mutating watch's commands always run in the apple/container VM, and that VM is not available: install the runtime and turn sandboxing on in Settings → Sandboxing, or leave the watch read-only."

    /// How the sandboxed branch of `run_command` reaches the container session. Injectable so a
    /// test can assert what that branch forwards — the command, the workspace, the extra mounts,
    /// the network and the deadline — without a `container` binary, a daemon or a VM. nil, the
    /// case everywhere in the app, means the one `SandboxSessionManager` the process shares.
    var sandboxSession: (@Sendable (_ command: String, _ conversationId: UUID, _ workspace: ContainerMount?,
                                    _ extraMounts: [String], _ network: NetworkMode, _ timeoutSeconds: Int) async -> String)?

    /// Where the no-conversation sandboxed branch of `run_command` finds the `container` CLI, or
    /// nil for "not installed". Injectable so a test can drive that branch against a stub binary
    /// instead of booting a real VM, whose failures under load have nothing to do with Iris (#374).
    /// nil — the case everywhere in the app — means `SandboxingManager.shared.containerBinaryPath`.
    var containerBinaryPath: (@Sendable () -> String?)?

    /// Where a one-off container's name is held while it runs, so the launch sweep spares it.
    /// Injectable so a test can read only its own names.
    var ephemeralRegistry: EphemeralContainerRegistry = .shared

    /// `workspaceToolsEnabled` defaults to "a Google refresh token is configured". Without one every
    /// Google Tasks / Workspace call fails, so the ten declarations were pure prompt weight (#133).
    /// Injectable so tests never mutate `ConfigManager.shared`.
    func getTools(workspaceToolsEnabled: Bool = !ConfigManager.shared.googleRefreshToken.isEmpty) async -> [FunctionDeclaration] {
        var tools = [
            FunctionDeclaration(
            name: "run_command",
            description: "Executes a shell command. Use this for standard operations. When the command exits on the host, any background process still holding its output pipes is killed; redirect its output (`cmd > log 2>&1 &`) to keep it running.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "command": Schema(type: "STRING", description: "The command to run in bash/zsh"),
                    "timeout_seconds": Schema(type: "INTEGER", description: "Optional timeout in seconds (default 600, max 3600). Set higher for long-running operations like docker builds or package installs. At the deadline the command and everything it started are killed.")
                ],
                required: ["command"]
            )
        ),
        FunctionDeclaration(
            name: "read_file",
            description: "Reads the contents of a file. Given a directory, lists its entries instead: one level, sorted, one per line, directories ending in `/`, capped in size.",
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "path": Schema(type: "STRING", description: "Absolute, tilde (~), or workspace-relative path to the file or directory. A relative path resolves against the conversation's bound workspace, not the app's directory.")
                ],
                required: ["path"]
            )
        ),
        FunctionDeclaration(
            name: "write_file",
            description: "Writes content to a file, overwriting existing content. Writing a skill's own SKILL.md this way still works (for hand-editing), but prefer create_skill/update_skill for a skill's frontmatter — they take title/tags and keep the prompt cache in sync for you.",
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
                    "overlap": Schema(type: "STRING", description: "`queue` or `skip`"),
                    "profile": Schema(type: "STRING", description: "'readOnly' (default) or 'mutating'. A watch that writes must be mutating; its commands then run in the sandbox VM, which must be available."),
                    "mounts": Schema(type: "ARRAY", description: "Directories the watch's runs may use, as '/host/dir', '/host/dir:ro' or '/host/dir:/path/in/container'. Read-write unless ':ro'; the first read-write one is the working directory. Mutating only. The watched folder is not included unless named here.", items: Schema(type: "STRING")),
                    "network": Schema(type: "BOOLEAN", description: "true lets the runs' commands reach the network from inside the VM; default false. Mutating only."),
                    "max_runs_per_hour": Schema(type: "INTEGER", description: "How many runs an hour before the watch pauses itself. On a new watch, omitting this takes the shared setting for watches (\(ConfigManager.JobDefaults.maxRunsPerHourForWatch) by default, which covers ordinary editing); on a re-registration, omitting it leaves whatever the watch already has. 0 removes the breaker entirely. Say a lower number for a folder that should rarely change.")
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
            description: IrisPaths.standard.agentFacing("Create a reusable procedural skill in the local skill library (~/.iris/memory/skills/<name>/SKILL.md)."),
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "name": Schema(type: "STRING", description: "Short kebab-case skill identifier (e.g. gke-deployment-debug). One folder name, not a path: empty, '.', '..' or anything containing '/' is refused."),
                    "description": Schema(type: "STRING", description: "High-signal summary of what this skill does and when to trigger it"),
                    "body": Schema(type: "STRING", description: "Full Markdown body containing numbered steps, exact commands, pitfalls, and verification steps"),
                    "title": Schema(type: "STRING", description: "Optional OKF `title:` frontmatter field — a human-readable display title, distinct from `name`. Omit to leave it unset."),
                    "tags": Schema(type: "ARRAY", description: "Optional OKF `tags:` frontmatter field — topic tags for this skill. Omit to leave it unset.", items: Schema(type: "STRING"))
                ],
                required: ["name", "description", "body"]
            )
        ),
        FunctionDeclaration(
            name: "update_skill",
            description: IrisPaths.standard.agentFacing("Update an existing skill in the local skill library (~/.iris/memory/skills/<name>/SKILL.md)."),
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "name": Schema(type: "STRING", description: "Skill identifier to update. One folder name, not a path: empty, '.', '..' or anything containing '/' is refused."),
                    "description": Schema(type: "STRING", description: "Updated description (optional if unchanged)"),
                    "body": Schema(type: "STRING", description: "Updated Markdown body or additional procedures (optional if description updated)"),
                    "title": Schema(type: "STRING", description: "Optional OKF `title:` frontmatter field. Omit to leave whatever the skill already has untouched."),
                    "tags": Schema(type: "ARRAY", description: "Optional OKF `tags:` frontmatter field. Omit to leave whatever the skill already has untouched.", items: Schema(type: "STRING"))
                ],
                required: ["name"]
            )
        ),
        FunctionDeclaration(
            name: "delete_skill",
            description: IrisPaths.standard.agentFacing("Delete a skill from the local skill library (~/.iris/memory/skills/<name>/SKILL.md)."),
            parameters: Schema(
                type: "OBJECT",
                properties: [
                    "name": Schema(type: "STRING", description: "The skill identifier to delete. One folder name, not a path: empty, '.', '..' or anything containing '/' is refused.")
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
    
    /// `grantedMount` is the covering mount the dispatcher decided on for this call (#282 §0.13).
    /// With a `grant` present the two file tools have exactly two outcomes: a non-nil decision is
    /// walked from that mount's root; a nil decision is refused (`notDecidedInsideGrant`). They
    /// reach Foundation on no branch. `grant == nil` (every attended call, every ungranted run) is
    /// today's path.
    ///
    /// `approvedWorkspaceRoot` is set by the dispatcher for a grader `read_file` spelled inside its
    /// contract's approved workspace (#339): that read is walked from the root by descriptor, with
    /// no symlink followed, whatever approved it — never opened by path.
    func execute(name: String, args: [String: JSONValue], cwd: String? = nil, conversationId: UUID? = nil,
                 useSandbox: Bool = false, grant: JobGrant? = nil, grantedMount: ContainerMount? = nil,
                 approvedWorkspaceRoot: String? = nil) async -> String {
        switch name {
        case "run_command":
            guard let command = args["command"]?.stringValue else { return "Error: Missing command" }
            let rawTimeout: Double = switch args["timeout_seconds"] {
            case .int(let i): Double(i)
            case .double(let d): d
            default: 600
            }
            let timeoutSeconds = min(max(rawTimeout, 10), 3600)
            return await runCommand(command, cwd: cwd, conversationId: conversationId, useSandbox: useSandbox,
                                    timeoutSeconds: timeoutSeconds, grant: grant)
        case "read_file":
            guard let path = args["path"]?.stringValue else { return "Error: Missing path" }
            if let grant {
                // §0.13: under a grant there is no Foundation branch. A nil decision is a refusal,
                // because it may have been made while a component was a link.
                guard let grantedMount else { return Self.notDecidedInsideGrant("read_file") }
                guard let relative = Self.grantedComponents(of: path, cwd: cwd, grant: grant, decided: grantedMount) else {
                    return Self.notUnderGrantedDirectory(grantedMount.source)
                }
                return await readFile(grantRoot: grantedMount.source, relative: relative)
            }
            if let approvedWorkspaceRoot {
                // The post-hook path: a `BeforeTool` rewrite out of the workspace is refused, not
                // opened by path on the strength of an approval given to another one.
                guard let relative = GoalContract.workspaceComponents(of: Self.resolvePath(path, cwd: cwd),
                                                                      under: approvedWorkspaceRoot) else {
                    return "Error: the path is not inside the approved workspace \(approvedWorkspaceRoot); nothing was read."
                }
                return await readFile(approvedWorkspace: approvedWorkspaceRoot, relative: relative)
            }
            return await readFile(path, cwd: cwd)
        case "write_file":
            guard let path = args["path"]?.stringValue, let content = args["content"]?.stringValue else { return "Error: Missing path or content" }
            if let grant {
                guard let grantedMount else { return Self.notDecidedInsideGrant("write_file") }
                guard let relative = Self.grantedComponents(of: path, cwd: cwd, grant: grant, decided: grantedMount) else {
                    return Self.notUnderGrantedDirectory(grantedMount.source)
                }
                return await writeFile(grantRoot: grantedMount.source, relative: relative, content: content)
            }
            return await writeFile(path, content: content, cwd: cwd, paths: irisPaths ?? .default)
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
            let title = ScheduleJobArguments.text(args["title"])
            switch Self.tagsArgument(args) {
            case .failure(let message): return "Error: " + message.text
            case .success(let tags):
                return await createSkill(name: name, description: description, body: body, title: title, tags: tags)
            }
        case "update_skill":
            guard let name = args["name"]?.stringValue else {
                return "Error: Missing name for update_skill"
            }
            let description = args["description"]?.stringValue
            let body = args["body"]?.stringValue ?? args["content"]?.stringValue
            let title = ScheduleJobArguments.text(args["title"])
            switch Self.tagsArgument(args) {
            case .failure(let message): return "Error: " + message.text
            case .success(let tags):
                return await updateSkill(name: name, description: description, body: body, title: title, tags: tags)
            }
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
    static let watchDescription = "Watch a directory for file changes and run your instructions once it has been quiet for a few seconds (default 3). It ignores its own file-tool writes, so a run can safely write into the folder. Calling it from Iris, or a conversation a peer or a background subagent reached, asks the user first."

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
    /// The watch breaker the answer quotes. Reads the live setting rather than the shipped constant,
    /// so a person who moved the Settings row is told the figure their watch will actually get.
    private var watchBreakerDefault: Int {
        let configured = watchBreakerProvider?() ?? ConfigManager.shared.jobMaxRunsPerHourForWatch
        return configured > 0 ? configured : ConfigManager.JobDefaults.maxRunsPerHourForWatch
    }

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
            let existing = watching.first(where: { $0.createdInConversationId == conversationId })
            let asked = parsed.profile?.lowercased() == JobProfile.mutating.rawValue.lowercased() ? JobProfile.mutating
                : (parsed.profile == nil ? nil : JobProfile.readOnly)
            let profile = asked ?? existing?.profile ?? .readOnly
            if profile == .mutating, !(mutatingJobsAvailable?() ?? SandboxPolicy.mutatingJobCanRun()) {
                return Self.watchProfileNeedsSandbox
            }
            let grant: JobGrant?
            switch JobGrant.resolve(mounts: parsed.mounts, network: parsed.network, profile: profile,
                                    paths: irisPaths ?? .default, home: homeDirectory ?? NSHomeDirectory()) {
            case .failure(let message):
                return "Not watching \(path): \(ScheduleJobArguments.grantRefusal(message, mountsNamed: !(parsed.mounts ?? []).isEmpty).text)"
            case .success(let resolved): grant = resolved
            }
            var job: Job
            let opening: String
            if var existing = existing, case .fsEvent(var watch) = existing.trigger {
                existing.prompt = parsed.instructions
                if let window { watch.quietWindowSeconds = window }
                if let ignore = parsed.ignore { watch.ignore = ignore }
                existing.trigger = .fsEvent(watch)
                if let overlap = parsed.overlap { existing.policy.overlap = overlap }
                // Omitted leaves the stored figure alone (§the original rule), so a watch created
                // before #283 keeps its old breaker until someone names one.
                if let runs = parsed.maxRunsPerHour { existing.policy.maxRunsPerHour = runs }
                existing.profile = profile
                existing.policy.grants = grant
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
                    profile: profile,
                    createdInConversationId: conversationId,
                    // A watch never runs concurrently with itself; by default a save that lands
                    // mid-run is queued, not dropped.
                    // Nothing stored unless the caller named a figure: nil means "the watch global"
                    // (#283), so the Settings row moves this watch like every other, and naming one
                    // here is a per-job override the way it is for a scheduled job.
                    policy: JobPolicy(overlap: parsed.overlap ?? .queue,
                                      maxRunsPerHour: parsed.maxRunsPerHour, grants: grant))
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
            // #283 review: a create at the default, a create at 0 and an update that kept a stored
            // figure all read identically without this. `0` especially has to be said out loud —
            // it removes the only bound on a loop the self-write filter cannot see.
            switch job.policy.maxRunsPerHour {
            case .none:
                sentences.append("It pauses itself past \(watchBreakerDefault) runs an hour, the shared setting for watches.")
            case .some(0):
                sentences.append("It has no breaker: nothing bounds how often it runs.")
            case .some(let runs):
                sentences.append("It pauses itself past \(runs) run\(runs == 1 ? "" : "s") an hour.")
            }
            if let grant = job.policy.grants { sentences.append(grant.sentence) }
            return sentences.joined(separator: " ")
        } catch {
            return "Could not save the watcher job."
        }
    }

    /// Internal, not private, so a test can drive a deadline below `execute`'s 10 s floor.
    func runCommand(_ command: String, cwd: String?, conversationId: UUID? = nil, useSandbox: Bool = false,
                    timeoutSeconds: Double = 600, grant: JobGrant? = nil) async -> String {
        // A grant is a promise about a container (#282). Off the sandboxed branch — sandboxing
        // resolved off, or no conversation to own a session — there is no container to keep it
        // in, and the host with `cwd` is not a fallback. The dispatcher refuses this upstream
        // (R20); this is the executor's own answer, so the seam cannot be handed a grant it drops.
        if grant != nil, !(useSandbox && conversationId != nil) {
            return IrisEngine.sandboxUnavailableRefusal(tool: "run_command")
        }
        if useSandbox, let conversationId {
            // The same deadline the host branch enforces, in seconds — the container runtime kills
            // the command on it. It used to be dropped here, which left a sandboxed command with
            // no bound at all while the model believed it had set one.
            let deadline = Int(timeoutSeconds)
            // §0.10: with a grant, the container's mounts are the grant's and nothing else — the
            // working directory from the grant, never from the conversation's workspace, which a
            // run must not be able to move. Without one, the workspace as today: an identity mount
            // of the expanded cwd, typed rather than spelled, so a `:` in the path reaches the
            // runtime as the entry it always did and is refused there. A grant with no read-write
            // mount yields nil here, i.e. `/`, not the cwd.
            let workspace: ContainerMount? = if let grant { grant.workspaceMount }
                                             else { cwd.map { ContainerMount(source: IrisEngine.expandTilde($0)) } }   // #275: no PATH_MAX truncation on a mount
            let extraMounts = grant?.extraMountEntries() ?? []
            let network = NetworkMode.forGrant(grant)
            if let sandboxSession {
                return await sandboxSession(command, conversationId, workspace, extraMounts, network, deadline)
            }
            guard SandboxingManager.shared.isContainerInstalled else {
                return "Error: sandboxing is on but the container runtime isn't installed. Open Iris Settings → Sandboxing to install it, or turn sandboxing off."
            }
            return await SandboxSessionManager.shared.run(command: command, conversationId: conversationId,
                                                          workspace: workspace, extraMounts: extraMounts,
                                                          network: network, timeoutSeconds: deadline)
        }
        let executable: String
        let arguments: [String]
        let directory: String?
        let environment: [String: String]?
        // Named, so a timeout or a cancel can delete it: killing the `container run` client does
        // not stop the container, and the command ran on in the VM (#353).
        var ephemeralContainer: (binary: String, name: String)? = nil
        if useSandbox {
            let resolvedContainerPath = if let containerBinaryPath { containerBinaryPath() }
                                        else { SandboxingManager.shared.containerBinaryPath }
            guard let containerPath = resolvedContainerPath else {
                return "Error: sandboxing is on but the container runtime isn't installed. Open Iris Settings → Sandboxing to install it, or turn sandboxing off."
            }
            executable = containerPath
            let name = "iris-run-\(UUID().uuidString.lowercased())"
            ephemeralContainer = (containerPath, name)
            var containerArgs = ["run", "--rm", "--name", name, ConfigManager.shared.sandboxImage, "bash", "-c", command]
            if let cwd = cwd {
                let expandedPath = IrisEngine.expandTilde(cwd)   // #275: never `expandingTildeInPath` on a decider
                // `-v`, where the session path uses `--mount` (see `ContainerMount`). The CLI
                // lowers both to the same virtiofs bind; this one is the ephemeral no-conversation
                // path and is left as it was rather than changed for symmetry alone.
                containerArgs.insert(contentsOf: ["-v", "\(expandedPath):\(expandedPath)", "--workdir", expandedPath], at: 4)
            }
            arguments = containerArgs
            directory = nil
            environment = nil
        } else {
            executable = "/bin/zsh"
            arguments = ["-c", command]
            directory = cwd.map { IrisEngine.expandTilde($0) }   // #275: never `expandingTildeInPath` on a decider
            environment = BinaryResolver.commandEnvironment(base: ProcessInfo.processInfo.environment)
        }

        // Its own process group, killed whole on timeout and on Stop: SIGTERM, then SIGKILL (#353).
        // Killing the shell's pid alone orphans whatever it forked — `sleep 30; true` — and an
        // orphan that inherited the pipes holds them open. After a normal exit, a background job
        // still holding the pipes is killed rather than waited on, so it cannot block the answer
        // (invariant 4); one that redirected its output is left running.
        let runner = ProcessGroupRunner()
        let registry = ephemeralRegistry
        // Killing the client leaves the container running, so the runner's ladder deletes it once
        // the client is dead — on the runner's queue, not in a `Task` here, which would wait for
        // a pool thread while the command ran on in the VM (#377).
        let ephemeralName = ephemeralContainer?.name
        let onKilled: (@Sendable () -> Void)?
        if let binary = ephemeralContainer?.binary, let name = ephemeralName {
            onKilled = { EphemeralContainerRegistry.deleteNow(binary: binary, name: name, registry: registry) }
        } else {
            onKilled = nil
        }
        do {
            return try await withTimeout(seconds: timeoutSeconds) {
                await withTaskCancellationHandler {
                    // Its name carries `SandboxSessionManager.namePrefix`: registered for its whole
                    // life so the launch sweep does not take it for an orphan (#364). Here, inside
                    // the work, not before `withTimeout`: a caller already cancelled never starts
                    // the work, and a name registered outside it was never given back.
                    if let ephemeralName { await registry.register(ephemeralName) }
                    let outcome = await runner.run(executable: executable, arguments: arguments,
                                                   environment: environment, currentDirectory: directory,
                                                   onKilled: onKilled)
                    // A killed run's hook gives the name back once the delete is done; any other
                    // ending left nothing in the VM (`--rm`, or no spawn at all).
                    if let ephemeralName, (try? outcome.get())?.killed != true {
                        await registry.unregister(ephemeralName)
                    }
                    let output: ProcessGroupRunner.Output
                    switch outcome {
                    case .success(let o): output = o
                    case .failure(let error): return "Error executing command: \(error.localizedDescription)"
                    }
                    var result = ""
                    if let outputStr = String(data: output.stdout, encoding: .utf8), !outputStr.isEmpty {
                        result += outputStr
                    }
                    if let errorStr = String(data: output.stderr, encoding: .utf8), !errorStr.isEmpty {
                        result += "\nStderr: " + errorStr
                    }
                    // When sandboxing is on and the `container` runtime failed to start the command
                    // (not provisioned: services down or no VM kernel), it emits opaque errors like
                    // "unauthorized request". Rewrite those to an actionable message so the model and
                    // user aren't left guessing (which previously led to confabulated "auth wall"
                    // explanations).
                    if useSandbox, output.status != 0, let hint = Self.sandboxSetupHint(for: result) {
                        return hint
                    }
                    return result.isEmpty ? "Success" : result
                } onCancel: {
                    // Safe before the launch too: the runner then never spawns. `Process.terminate()`
                    // raised on a process that had not been launched yet.
                    runner.terminate()
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
        // #275: `expandingTildeInPath` truncates to PATH_MAX and hands back a plausible path; every
        // allow-side expansion passes through here (#282 §0.9), so it keeps every byte.
        let expanded = IrisEngine.expandTilde(path)
        guard !(expanded as NSString).isAbsolutePath, let cwd = cwd else { return expanded }
        let base = IrisEngine.expandTilde(cwd)
        return URL(fileURLWithPath: base).appendingPathComponent(expanded).path
    }

    private func readFile(_ path: String, cwd: String? = nil) async -> String {
        let expandedPath = Self.resolvePath(path, cwd: cwd)
        return await Task.detached {
            // A directory gets its listing (#337). `O_NONBLOCK` so a FIFO is not opened blocking
            // here; it fails `O_DIRECTORY` and falls through to the read, as before.
            let dirFD = open(expandedPath, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC)
            if dirFD >= 0 {
                defer { close(dirFD) }
                do { return try DirectoryListing.list(directory: dirFD) }
                catch let error as GrantedFileError { return "Error reading directory: \(error.message)" }
                catch { return "Error reading directory: \(error.localizedDescription)" }
            }
            do {
                return try String(contentsOfFile: expandedPath, encoding: .utf8)
            } catch {
                return "Error reading file: \(error.localizedDescription)"
            }
        }.value
    }

    /// `paths` is read only to decide whether this write lands on a skill's own `SKILL.md`
    /// (#417 item 2) — a `write_file` call carries no other signal of that. On a plain write
    /// (anywhere else) it changes nothing.
    private func writeFile(_ path: String, content: String, cwd: String? = nil, paths: IrisPaths = .default) async -> String {
        let expandedPath = Self.resolvePath(path, cwd: cwd)
        let targetedSkillFolder = Self.skillFileTarget(expandedPath, paths: paths)
        let result = await Task.detached {
            do {
                try content.write(toFile: expandedPath, atomically: true, encoding: .utf8)
                return "Successfully wrote to \(expandedPath)"
            } catch {
                return "Error writing file: \(error.localizedDescription)"
            }
        }.value
        guard result.hasPrefix("Successfully wrote to"), let targetedSkillFolder else { return result }
        // A `write_file` landing on a skill's own SKILL.md deliberately does not get funnelled
        // through `update_skill`'s slug-and-reconstruct path (#417 item 2): that path is also
        // how a user hand-edits a skill outside the model entirely, and rewriting their exact
        // content into OKF-reconstructed form would silently change what they wrote. What a
        // plain Foundation write must not skip is the prompt cache — the engine's skill list
        // goes stale until something else invalidates it — and a check of what landed, surfaced
        // as a warning rather than a refusal (`write_file` must still work for a skill the user
        // is actively editing by hand, even mid-edit).
        await AppState.shared.invalidateEnginePrompt()
        var suffix = " Skill prompt cache invalidated."
        let warnings = SkillFrontmatter.warnings(content: content, folderName: targetedSkillFolder)
        if !warnings.isEmpty {
            suffix += " Warning: this skill's frontmatter may not load as expected:\n"
                + warnings.map { "- \($0)" }.joined(separator: "\n")
        }
        return result + suffix
    }

    /// Whether `expandedPath` is a skill's own `SKILL.md` — one level directly under the skills
    /// directory — and if so, that skill's folder name. Resolved the same symlink-safe way
    /// `skillFolder(named:)` resolves a name to a folder, but starting from the path a
    /// `write_file` call gives rather than a tool-given name.
    ///
    /// `.standardizedFileURL` lexically collapses a `.`/`..` component before anything else runs
    /// (#417 PR review item 4: `foo/./SKILL.md` named its folder `.`, not `foo`, without this).
    /// The filename compares case-insensitively (item 3): APFS is case-insensitive by default, so
    /// `skills/foo/skill.md` and `skills/foo/SKILL.md` are the *same file*, and a write to the
    /// lowercase spelling silently overwrote the real one with no cache invalidation or warning.
    static func skillFileTarget(_ expandedPath: String, paths: IrisPaths = .default) -> String? {
        let url = URL(fileURLWithPath: expandedPath).standardizedFileURL
        guard url.lastPathComponent.caseInsensitiveCompare("SKILL.md") == .orderedSame else { return nil }
        let folder = url.deletingLastPathComponent()
        guard !folder.lastPathComponent.isEmpty else { return nil }
        let resolvedSkillsDir = IrisPaths.realPath(paths.skillsDir.path).lowercased()

        // The common case: the write names a child directly under the skills dir (including
        // through a symlinked skills dir — resolving `folder`'s *parent* resolves that).
        let resolvedParent = IrisPaths.realPath(folder.deletingLastPathComponent().path).lowercased()
        if resolvedParent == resolvedSkillsDir { return folder.lastPathComponent }

        // A write straight to a skill folder symlink's real target, bypassing the symlink
        // itself (#417 PR review item 5): by the time that path is walked neither side still
        // looks like a symlink, so the forward comparison above can never match it. Resolve the
        // other direction instead — each of the skills dir's own entries — and match on that.
        let resolvedFolder = IrisPaths.realPath(folder.path).lowercased()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: paths.skillsDir.path) else {
            return nil
        }
        for entry in entries {
            let candidate = paths.skillsDir.appendingPathComponent(entry).path
            if IrisPaths.realPath(candidate).lowercased() == resolvedFolder { return entry }
        }
        return nil
    }

    // No "Error: " prefix, matching `ScheduleJobArguments.mountsShape`: the dispatch switch below
    // prepends it, the same way `RegisterWatcherArguments` does for `mounts`.
    static let tagsShape: ToolMessage = "tags must be a list of short strings, e.g. [\"kubernetes\", \"debugging\"]."

    /// `create_skill`/`update_skill`'s `tags` argument, read so a caller can tell "not asked"
    /// (`nil`) from "asked to clear" (`[]`) from "asked to set" (non-empty) (#417 PR review item
    /// 9). `ScheduleJobArguments.stringList`, used for `mounts`/`ignore` elsewhere, treats an
    /// empty list as "nothing asked" — right for those, but it would make `tags: []` a silent
    /// no-op here, with no way for a model to ever clear a skill's tags once set.
    static func tagsArgument(_ args: [String: JSONValue]) -> Result<[String]?, ToolMessage> {
        guard ScheduleJobArguments.present(args["tags"]), let value = args["tags"] else { return .success(nil) }
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(trimmed.isEmpty ? [] : [trimmed])
        case .array(let items):
            var values: [String] = []
            for item in items {
                guard case .string = item, let text = ScheduleJobArguments.text(item) else { return .failure(Self.tagsShape) }
                values.append(text)
            }
            return .success(values)
        default:
            return .failure(Self.tagsShape)
        }
    }

    /// A granted run's read (#282 §0.13): the same walk the write takes, from the covering mount's root.
    func readFile(grantRoot: String, relative: [String]) async -> String {
        await Task.detached {
            do { return try GrantedFileAccess(root: grantRoot).read(relative: relative) }
            catch let error as GrantedFileError { return "Error reading file: \(error.message)" }
            catch { return "Error reading file: \(error.localizedDescription)" }
        }.value
    }

    /// A grader's pre-approved read in its approved workspace (#339): the granted-run walk, from
    /// the approved root.
    func readFile(approvedWorkspace root: String, relative: [String]) async -> String {
        await Task.detached {
            do { return try GrantedFileAccess(root: root).read(relative: relative) }
            catch let error as GrantedFileError { return "Error reading file: \(error.message(for: .approvedWorkspace))" }
            catch { return "Error reading file: \(error.localizedDescription)" }
        }.value
    }

    /// A granted run's write (#282 §0.13). The success sentence is the one `IrisEngine.writtenPaths`
    /// reads, so the self-write filter is fed exactly as for a Foundation write.
    func writeFile(grantRoot: String, relative: [String], content: String) async -> String {
        let path = ([grantRoot] + relative).joined(separator: "/")
        return await Task.detached {
            do {
                try GrantedFileAccess(root: grantRoot).write(relative: relative, content: content)
                return "Successfully wrote to \(path)"
            } catch let error as GrantedFileError { return "Error writing file: \(error.message)" }
            catch { return "Error writing file: \(error.localizedDescription)" }
        }.value
    }

    /// The components the walk descends for a granted file-tool call, or nil. `path` is the
    /// post-hook path, so nothing decided upstream is relied on: it must be spelled under the
    /// DECIDED mount (`relativeComponents`), and its real path must still be covered by that same
    /// entry — equality with the decision, never a fresh decision — so a `BeforeTool` rewrite into
    /// a nested read-only entry beneath the decided mount (where a command would get EROFS) is
    /// refused rather than walked from the outer root. A link out of the mount fails here too; a
    /// link that stays inside is left to the walk, whose sentence names it.
    private static func grantedComponents(of path: String, cwd: String?, grant: JobGrant,
                                          decided: ContainerMount) -> [String]? {
        guard let relative = grant.relativeComponents(of: path, cwd: cwd, under: decided),
              let real = IrisPaths.realPathForAllow(resolvePath(path, cwd: cwd)),
              grant.covering(real)?.source == decided.source else { return nil }
        return relative
    }

    static func notUnderGrantedDirectory(_ source: String) -> String {
        "Error: the path is not under the granted directory \(source); nothing was done."
    }

    static func notDecidedInsideGrant(_ tool: String) -> String {
        "Error: `\(tool)` was not inside this run's grant when it was decided; nothing was done — widen the grant (re-schedule) if it should be."
    }
    
    private func searchWeb(query: String) async -> String {
        await Self.runSearchWeb(query: query)
    }

    /// DuckDuckGo's lite search endpoint, the real `search_web` target. A parameter of
    /// `runSearchWeb` rather than baked into the script, so a test can point the script at a
    /// local stub instead of the network (#431).
    static let duckDuckGoURL = "https://lite.duckduckgo.com/lite/"

    /// Deadline for the whole `search_web` subprocess, start to exit (#431). Independent of the
    /// script's own network `timeout=`: that bounds `urlopen`, this bounds the process, so a
    /// stall anywhere else in the interpreter — a hung DNS resolver, a stuck SSL handshake that
    /// never reaches a socket read — is still killed with its process group (invariant 4).
    static let searchWebTimeoutSeconds: Double = 30

    static func searchWebTimedOutMessage(seconds: Double) -> String {
        "Error: search timed out after \(Int(seconds))s"
    }

    /// The testable core of `search_web`: writes the script, runs it bounded by
    /// `processTimeoutSeconds` through `ProcessGroupRunner.capture` (never a bare pool
    /// `Task.sleep`, invariant 4), and returns its output or a timeout message. `targetURL` and
    /// `networkTimeoutSeconds` are injectable so a test can point the script at a local stub that
    /// accepts and never responds, instead of the real network, and keep the bounds short (#431).
    static func runSearchWeb(query: String, targetURL: String = Self.duckDuckGoURL,
                             networkTimeoutSeconds: Int = 15,
                             processTimeoutSeconds: Double = Self.searchWebTimeoutSeconds,
                             irisDir: URL = IrisPaths.default.root) async -> String {
        let script = """
import urllib.request
import urllib.parse
import urllib.error
from html.parser import HTMLParser
import sys
import json
import os
import socket
import ssl

# Bounds urlopen's connect and each blocking read (#431): a server that accepts the connection
# and then stalls would otherwise hold this process forever.
_NETWORK_TIMEOUT_SECONDS = \(networkTimeoutSeconds)
_TARGET_URL = \(String(reflecting: targetURL))


def _ssl_context():
    # A python.org framework build has no default CA file (its
    # ssl.get_default_verify_paths().cafile is None until the "Install
    # Certificates.command" step is run), so every HTTPS request fails with
    # CERTIFICATE_VERIFY_FAILED. Prefer the macOS system bundle, then certifi.
    ctx = ssl.create_default_context()
    if ssl.get_default_verify_paths().cafile is None:
        if os.path.exists("/etc/ssl/cert.pem"):
            ctx.load_verify_locations(cafile="/etc/ssl/cert.pem")
        else:
            try:
                import certifi
                ctx.load_verify_locations(cafile=certifi.where())
            except Exception:
                pass
    return ctx


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
req = urllib.request.Request(_TARGET_URL, data=data, headers={"User-Agent": "Mozilla/5.0"})
try:
    # `timeout=` bounds the connect and each blocking read (#431): without it, a server that
    # accepts the connection and then stalls holds `urlopen` forever.
    html = urllib.request.urlopen(req, timeout=_NETWORK_TIMEOUT_SECONDS, context=_ssl_context()).read().decode("utf-8")
    parser = DDGParser()
    parser.feed(html)
    print(json.dumps(parser.results[:10], indent=2))
except (socket.timeout, TimeoutError) as e:
    print(f"search_web: network request timed out after {_NETWORK_TIMEOUT_SECONDS}s: {e}", file=sys.stderr)
    sys.exit(1)
except urllib.error.URLError as e:
    if isinstance(e.reason, (socket.timeout, TimeoutError)):
        print(f"search_web: network request timed out after {_NETWORK_TIMEOUT_SECONDS}s: {e}", file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"error": str(e)}))
except Exception as e:
    print(json.dumps({"error": str(e)}))
"""
        // Through `IrisPaths`, not the home directory: this was the one writer that bypassed it,
        // so a test calling `search_web` would have written the real `~/.iris` (#304).
        try? FileManager.default.createDirectory(at: irisDir, withIntermediateDirectories: true)
        let scriptURL = irisDir.appendingPathComponent("search_web.py")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return "Error executing search script: \(error)"
        }
        let command = Self.searchWebCommand(scriptPath: scriptURL.path, query: query)
        // Bounds the whole call, not just the script's own `urlopen` timeout: if the interpreter
        // hangs for any other reason, the process group is still killed on schedule, on this
        // runner's own queue rather than a pool `Task.sleep` (invariant 4, #431).
        let outcome = await ProcessGroupRunner.capture(
            executable: command.executable, arguments: command.arguments, environment: command.environment,
            mergeStderr: true, timeoutSeconds: processTimeoutSeconds)
        switch outcome {
        case .failure(let error):
            return "Error executing search script: \(error)"
        case .success(let output):
            if output.timedOut {
                return Self.searchWebTimedOutMessage(seconds: processTimeoutSeconds)
            }
            let text = String(data: output.stdout, encoding: .utf8) ?? "Error decoding output"
            if Self.isTLSTrustMissing(text) {
                return "search_web is unavailable: TLS trust store missing — tell the user"
            }
            return text
        }
    }

    /// The executable, arguments and environment `searchWeb`'s subprocess runs with: `/usr/bin/env
    /// python3 <script> <query>`, the login-shell PATH applied (#228) and the macOS trust store
    /// exposed via `SSL_CERT_FILE` when needed (#243). Separate from `searchWeb` so a test can
    /// assert on them without running the search, which would hit the network.
    static func searchWebCommand(scriptPath: String, query: String,
                                 environment: [String: String] = ProcessInfo.processInfo.environment)
        -> (executable: String, arguments: [String], environment: [String: String]) {
        let env = Self.sslCertEnvironment(base: BinaryResolver.commandEnvironment(base: environment))
        return (executable: "/usr/bin/env", arguments: ["python3", scriptPath, query], environment: env)
    }

    /// The `Process` form of `searchWebCommand`, kept for tests that assert on `Process.environment`
    /// directly. `searchWeb` itself runs through `ProcessGroupRunner.capture` (#431), not `Process`.
    static func searchWebProcess(scriptPath: String, query: String,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> Process {
        let command = Self.searchWebCommand(scriptPath: scriptPath, query: query, environment: environment)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        return process
    }

    /// Adds `SSL_CERT_FILE` to the environment when the macOS system trust store exists and the
    /// variable isn't already set, so a python.org framework python3 (which has no default CA file)
    /// can verify TLS in `search_web` (#243). Static and injectable (`certFile`) so a test can pass
    /// a temp path or a nonexistent one without touching the real system file.
    static func sslCertEnvironment(base: [String: String], certFile: String = "/etc/ssl/cert.pem") -> [String: String] {
        var env = base
        if env["SSL_CERT_FILE"] == nil && FileManager.default.fileExists(atPath: certFile) {
            env["SSL_CERT_FILE"] = certFile
        }
        return env
    }

    /// Whether the search script's output reports the specific TLS-trust-store failure mode
    /// (python.org framework python3 without a CA bundle). Surfaced as a distinct message so the
    /// model tells the user rather than silently falling back to curl/apt-get (#243).
    static func isTLSTrustMissing(_ output: String) -> Bool {
        output.range(of: "CERTIFICATE_VERIFY_FAILED", options: .caseInsensitive) != nil
    }

    /// Where a skill of this name lives: the one spelling of the folder, for the three tools that
    /// write it and for the dispatcher, which has to work out what a skill call wrote from its
    /// arguments (the tools take no path, so there is nothing else to read; #187 §4).
    ///
    /// The name is slugged the same way for all three — lowercased, trimmed, spaces and
    /// underscores to dashes. `deleteSkill` used to lowercase and trim but not replace, so
    /// `delete_skill` with the name `my skill` looked for a folder `create_skill` had never made.
    /// nil when the name cannot address a folder *inside* `skillsDir` (#284). The slug leaves `..`
    /// and `/` alone, and `appendingPathComponent` treats a `/` as a path separator rather than a
    /// literal, so before this guard `delete_skill` could remove a tree outside the skills
    /// directory — measured: `"../../x"` reached `~/x`, `".."` reached `~/.iris` itself, and an
    /// empty name reached `~/.iris/skills`, so a blank argument deleted every skill.
    ///
    /// A name is one path component, non-empty, not `.` or `..`, with no control characters, and
    /// Foundation must keep it as given: it truncates a path at U+0000, so `"..\u{0}"` passed every
    /// string rule and acted on `skills/..` (#307 review). Containment is checked lexically, so a
    /// skill folder that is a symlink into a git checkout is supported (#305): writes land in its
    /// target and a delete removes only the link. Two link targets are refused: `config/` and
    /// `plugins/`, which the skill tools would otherwise write with no approval while `write_file`
    /// is refused there (#282 §0.9), and the skills directory or anything above it, which would
    /// put `SKILL.md` into the skills directory itself.
    static func skillFolder(named name: String, paths: IrisPaths = .default) -> URL? {
        let cleanName = name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        guard !cleanName.isEmpty, !cleanName.contains("/"), cleanName != ".", cleanName != "..",
              !cleanName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        let folder = paths.skillsDir.appendingPathComponent(cleanName)
        guard folder.lastPathComponent == cleanName,
              folder.deletingLastPathComponent().path == paths.skillsDir.path else { return nil }
        guard !paths.isUnderProtectedWriteDir(folder.path) else { return nil }
        let resolved = IrisPaths.realPath(folder.path).lowercased()
        let skillsResolved = IrisPaths.realPath(paths.skillsDir.path).lowercased()
        // `/` is everything's ancestor, but `"/" + "/"` prefixes nothing, so it is named outright.
        guard resolved != "/", skillsResolved != resolved, !skillsResolved.hasPrefix(resolved + "/") else { return nil }
        return folder
    }

    /// A skill folder that is a symlink whose target is gone. `fileExists` follows links, so
    /// without this a moved checkout read as "not found" and its name could never be reused.
    static func isDanglingLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
            && !FileManager.default.fileExists(atPath: url.path)
    }

    static func brokenLinkMessage(_ name: String) -> String {
        "Error: skill '\(name)' is a broken link — its folder is a symlink whose target no longer exists. Delete the skill to remove the link."
    }

    /// One sentence for all three tools, so a refusal reads the same wherever it comes from.
    static let invalidSkillName = "Error: that is not a valid skill name — a skill name is a single folder name, not a path."

    func createSkill(name: String, description: String, body: String, title: String? = nil,
                     tags: [String]? = nil, paths: IrisPaths = .default) async -> String {
        guard let skillFolder = Self.skillFolder(named: name, paths: paths) else { return Self.invalidSkillName }
        let cleanName = skillFolder.lastPathComponent
        if Self.isDanglingLink(skillFolder) { return Self.brokenLinkMessage(cleanName) }
        let skillFile = skillFolder.appendingPathComponent("SKILL.md")

        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: Date())
        let frontmatter = SkillFrontmatter.render(name: cleanName, title: title, description: description,
                                                  type: "skill", tags: tags, timestamp: timestamp, existing: [])

        let okfContent = """
        ---
        \(frontmatter)
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

    func updateSkill(name: String, description: String?, body: String?, title: String? = nil,
                     tags: [String]? = nil, paths: IrisPaths = .default) async -> String {
        guard let skillFolder = Self.skillFolder(named: name, paths: paths) else { return Self.invalidSkillName }
        let cleanName = skillFolder.lastPathComponent
        if Self.isDanglingLink(skillFolder) { return Self.brokenLinkMessage(cleanName) }
        let skillFile = skillFolder.appendingPathComponent("SKILL.md")
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: skillFile.path) else {
            let desc = description ?? "No description provided."
            let content = body ?? "No procedure steps provided."
            return await createSkill(name: cleanName, description: desc, body: content, title: title, tags: tags, paths: paths)
        }

        var existingFields: [SkillFrontmatterField] = []
        var existingBody = ""
        var lineEnding = "\n"

        if let existingContent = try? String(contentsOf: skillFile, encoding: .utf8) {
            // Captured on the raw content, before `parse` normalizes CRLF to `\n` internally —
            // the only way the file's own line ending survives a rewrite (#417 PR review item 6).
            lineEnding = SkillFrontmatter.lineEnding(of: existingContent)
            (existingFields, existingBody) = SkillFrontmatter.parse(existingContent)
        }

        let finalBody = body ?? existingBody

        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: Date())
        // `description`/`type` pass straight through as given — `nil` means `render` carries the
        // existing field's raw lines over unchanged, which is what keeps a multi-line
        // `description:` (a folded `>`/literal `|` block, or a plain scalar wrapped onto a
        // continuation line) from being truncated to its first line on an update that never
        // mentioned `description` (#417 PR review, blocking finding). `type` isn't a tool
        // parameter at all, so it is always `nil` here — always carried over or defaulted.
        let frontmatter = SkillFrontmatter.render(name: cleanName, title: title, description: description,
                                                  type: nil, tags: tags, timestamp: timestamp,
                                                  existing: existingFields)

        let okfContent = """
        ---
        \(frontmatter)
        ---

        \(finalBody)
        """
        let finalContent = lineEnding == "\r\n" ? okfContent.replacingOccurrences(of: "\n", with: "\r\n") : okfContent

        do {
            try finalContent.write(to: skillFile, atomically: true, encoding: .utf8)
            await AppState.shared.invalidateEnginePrompt()
            return "Successfully updated skill '\(cleanName)' in \(skillFile.path). System prompt cache updated."
        } catch {
            return "Error updating skill '\(cleanName)': \(error.localizedDescription)"
        }
    }

    func deleteSkill(name: String, paths: IrisPaths = .default) async -> String {
        guard let skillFolder = Self.skillFolder(named: name, paths: paths) else { return Self.invalidSkillName }
        let cleanName = skillFolder.lastPathComponent
        let fileManager = FileManager.default
        // `attributesOfItem` does not follow a link, so a dangling one is still found and removed.
        guard (try? fileManager.attributesOfItem(atPath: skillFolder.path)) != nil else {
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
