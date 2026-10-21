import Testing
import Foundation
@testable import IrisKit

/// #688: script jobs that write. The fingerprint covers a writing job's grant and profile without
/// changing a read-only job's; each read-write mount is surveyed for repositories and size; the
/// fire refuses, pauses or runs by what the surveys say.
@Suite("Writing script jobs (#688)", .timeLimit(.minutes(1)))
struct WritingScriptJobsTests {
    private let spec = ScriptSpec(command: "tidy", mounts: [], timeoutSeconds: 30, network: false)

    private func tempDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-688-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return IrisPaths.canonicalPath(dir.path)
    }

    // MARK: The fingerprint

    @Test("a read-only script job's fingerprint is byte-identical to #698's; a grant, a flag or the profile changes it")
    func fingerprintIsAdditive() {
        #expect(spec.fingerprint(profile: .readOnly, grant: nil) == spec.fingerprint)
        let grant = JobGrant(mounts: [ContainerMount(source: "/w", target: "/w", readOnly: false)], network: false)
        let writing = spec.fingerprint(profile: .mutating, grant: grant)
        #expect(writing != spec.fingerprint)
        let flipped = JobGrant(mounts: [ContainerMount(source: "/w", target: "/w", readOnly: true)], network: false)
        #expect(spec.fingerprint(profile: .mutating, grant: flipped) != writing, "a mount's flag is reviewed")
        #expect(spec.fingerprint(profile: .readOnly, grant: grant) != writing, "the profile is reviewed")
        let networked = JobGrant(mounts: grant.mounts, network: true)
        #expect(spec.fingerprint(profile: .mutating, grant: networked) != writing, "the grant's network is reviewed")
    }

    // MARK: The survey

    @Test("a survey counts files and bytes, and finds a repository at the root or anywhere inside")
    func surveyFindsRepositories() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        try Data(count: 100).write(to: URL(fileURLWithPath: root + "/a.bin"))
        try FileManager.default.createDirectory(atPath: root + "/sub/deep/.git/hooks", withIntermediateDirectories: true)
        try Data(count: 50).write(to: URL(fileURLWithPath: root + "/sub/b.bin"))
        let found = WritingScripts.survey(root)
        #expect(!found.capped)
        #expect(found.bytes == 150)
        #expect(found.repositories == [root + "/sub/deep"])
        try "gitdir: /elsewhere".write(toFile: root + "/.git", atomically: true, encoding: .utf8)   // a gitfile
        #expect(WritingScripts.survey(root).repositories.contains(root))
    }

    @Test("a bare repository (HEAD, objects/, refs/, no .git) is found at the root or inside, and refused (#739 review)")
    func surveyFindsBareRepositories() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        func makeBare(_ at: String) throws {
            try FileManager.default.createDirectory(atPath: at + "/objects", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: at + "/refs", withIntermediateDirectories: true)
            try "ref: refs/heads/main\n".write(toFile: at + "/HEAD", atomically: true, encoding: .utf8)
        }
        try makeBare(root + "/remotes/origin.git")
        let found = WritingScripts.survey(root)
        #expect(found.repositories == [root + "/remotes/origin.git"])
        #expect(WritingScripts.refusal([(root, found)]) == GateEvaluator.writingScriptRepositoryRefusal(root + "/remotes/origin.git"))
        let bareRoot = try tempDir(); defer { try? FileManager.default.removeItem(atPath: bareRoot) }
        try makeBare(bareRoot)
        #expect(WritingScripts.survey(bareRoot).repositories == [bareRoot])
        // A folder that merely has a HEAD file isn't one.
        let notBare = try tempDir(); defer { try? FileManager.default.removeItem(atPath: notBare) }
        try "x".write(toFile: notBare + "/HEAD", atomically: true, encoding: .utf8)
        #expect(WritingScripts.survey(notBare).repositories.isEmpty)
    }

    @Test("a folder the walk can't read makes the survey incomplete, which refuses the mount (#739 review)")
    func unreadableFailsClosed() throws {
        let root = try tempDir()
        let locked = root + "/locked"
        try FileManager.default.createDirectory(atPath: locked + "/inner", withIntermediateDirectories: true)
        chmod(locked, 0o000)
        defer { chmod(locked, 0o755); try? FileManager.default.removeItem(atPath: root) }
        let found = WritingScripts.survey(root)
        #expect(!found.isComplete && found.incomplete?.contains("can't be read") == true)
        #expect(WritingScripts.refusal([(root, found)])?.contains("can't be checked for repositories") == true)
    }

    @Test("a survey stops at its cap, and a capped mount can't be shown free of repositories")
    func surveyCaps() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        for i in 0..<20 { try Data().write(to: URL(fileURLWithPath: root + "/f\(i)")) }
        let capped = WritingScripts.survey(root, entryCap: 5)
        #expect(capped.capped)
        #expect(WritingScripts.refusal([(root, capped)])?.contains("too large to check for repositories") == true)
    }

    @Test("a survey doesn't follow a link out of the mount")
    func surveyFollowsNoLink() throws {
        let root = try tempDir(), outside = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createDirectory(atPath: outside + "/.git", withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: URL(fileURLWithPath: outside + "/big"))
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: outside)
        let found = WritingScripts.survey(root)
        #expect(found.repositories.isEmpty && found.bytes == 0)
    }

    // MARK: The rules

    @Test("refusals name the repository found, and the floor names the disk's free space")
    func refusalsAndFloor() {
        let repo = MountSurvey(entries: 3, bytes: 0, repositories: ["/w/app"], capped: false)
        #expect(WritingScripts.refusal([("/w", repo)]) == GateEvaluator.writingScriptRepositoryRefusal("/w/app"))
        #expect(WritingScripts.refusal([("/w", MountSurvey(entries: 3, bytes: 0, repositories: [], capped: false))]) == nil)
        #expect(WritingScripts.floorRefusal(["/w"], freeBytes: { _ in 4 * 1_073_741_824 })?.contains("under the 5 GB") == true)
        #expect(WritingScripts.floorRefusal(["/w"], freeBytes: { _ in 6 * 1_073_741_824 }) == nil)
    }

    @Test("a run that grows, shrinks or empties a mount past its thresholds, or makes a repository, pauses the job")
    func pauseThresholds() {
        func figures(_ before: (Int, Int64), _ after: (Int, Int64), made: [String] = [], capped: Bool = false) -> [MountFigures] {
            [MountFigures(source: "/w", before: MountSurvey(entries: before.0, bytes: before.1, repositories: [], capped: false),
                          after: MountSurvey(entries: after.0, bytes: after.1, repositories: made, capped: capped))]
        }
        let gb: Int64 = 1_073_741_824
        #expect(WritingScripts.pauseReason(figures((100, gb), (110, gb + gb / 2))) == nil, "ordinary growth")
        #expect(WritingScripts.pauseReason(figures((100, gb), (110, 4 * gb)))?.contains("added") == true)
        #expect(WritingScripts.pauseReason(figures((100, 10 * gb), (100, 7 * gb)))?.contains("removed") == true, "a byte loss over 20%")
        #expect(WritingScripts.pauseReason(figures((10_000, gb), (7_000, gb)))?.contains("removed 3000 files") == true, "a count drop over 20%")
        #expect(WritingScripts.pauseReason(figures((100, gb), (100, gb), made: ["/w/new"]))?.contains("/w/new") == true)
        let cappedAfter = figures((100, gb), (110, 4 * gb), capped: true)
        #expect(WritingScripts.pauseReason(cappedAfter)?.contains("couldn't finish checking") == true, "a capped after-walk fails closed")
        #expect(WritingScripts.failsRun(cappedAfter))
        #expect(!WritingScripts.failsRun(figures((100, gb), (110, 4 * gb))), "growth pauses but doesn't fail the run")
        #expect(WritingScripts.madeRepository(figures((1, 0), (1, 0), made: ["/w/new"])) == "/w/new")
    }

    // MARK: Creation

    @Test("a writing script job takes the grant's mounts, never script_mounts or script_network, and a read-only one the reverse")
    func creationArguments() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        func make(_ args: [String: JSONValue]) -> Result<Job, ToolMessage> {
            guard case .success(let parsed) = ScheduleJobArguments.parse(args) else { return .failure("unparsed") }
            return parsed.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: [], sandboxAvailable: true)
        }
        let base: [String: JSONValue] = ["script": .string("tidy"), "intervalSeconds": .int(3600)]
        var writing = base
        writing["profile"] = .string("mutating")
        writing["mounts"] = .array([.string(dir)])
        let job = try make(writing).get()
        #expect(job.profile == .mutating && job.effectiveGrant?.mounts.first?.readOnly == false)
        var mixed = writing
        mixed["script_mounts"] = .array([.string(dir)])
        #expect(throws: ToolMessage.self) { try make(mixed).get() }
        var readOnly = base
        readOnly["mounts"] = .array([.string(dir)])
        #expect(throws: ToolMessage.self) { try make(readOnly).get() }
    }

    @Test("the VM gets the grant's mounts read-write, each with its .iris/ read-only over it, on the grant's network; a repository root is refused")
    func vmMounts() async throws {
        let dir = try tempDir(), home = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(atPath: home) }
        let grant = JobGrant(mounts: [ContainerMount(source: dir, target: dir, readOnly: false)], network: false)
        let runtime = GateRuntime()
        runtime.execResult = ("tidied\n", "", 0)
        let paths = IrisPaths(root: URL(fileURLWithPath: home))
        let guardFile = URL(fileURLWithPath: home).appendingPathComponent("guard.json")
        let result = await GateEvaluator.runWritingScriptJob(spec, grant: grant, runtime: runtime, image: "ubuntu:latest",
                                                             paths: paths, gitGuard: GitConfigGuard(store: guardFile))
        #expect(result == .ran(stdout: "tidied\n", stderr: "", exitCode: 0))
        #expect(runtime.createdMounts.contains("\(dir):\(dir)"), "read-write, no :ro: \(runtime.createdMounts)")
        #expect(runtime.createdMounts.contains("\(dir)/.iris:\(dir)/.iris:ro"))
        #expect(WritableRootsRecord(paths: paths).all().contains(dir), "recorded before the container (#616)")
        try FileManager.default.createDirectory(atPath: dir + "/.git", withIntermediateDirectories: true)
        let refused = await GateEvaluator.runWritingScriptJob(spec, grant: grant, runtime: runtime, image: "ubuntu:latest",
                                                              paths: paths, gitGuard: GitConfigGuard(store: guardFile))
        #expect(refused == .failed(GateEvaluator.writingScriptRepositoryRefusal(dir)))
    }

    @Test("the review names what the script can change and delete, and its network, beside the folders")
    func reviewText() {
        let grant = JobGrant(mounts: [ContainerMount(source: "/w", target: "/w", readOnly: false)], network: true)
        let text = ScriptJobs.reviewDetails(spec, isGate: false, grant: grant)
        #expect(text.contains("/w \u{2192} /w, read-write"))
        #expect(text.contains("change and delete files in /w on every run"))
        #expect(text.contains("reach the internet"))
        #expect(text.contains("less than 5 GB free"))
        #expect(text.hasSuffix("Script:\ntidy"))
    }
}

/// The fire, through a real runner over a real ledger, with the VM, the surveys and the free space
/// injected.
@MainActor
@Suite("Writing script job fires (#688)", .timeLimit(.minutes(1)))
struct WritingScriptJobRunTests {
    private let spec = ScriptSpec(command: "tidy", mounts: [], timeoutSeconds: 30, network: false)

    private func harness() throws -> (ConversationStore, AppState, IrisEngine, ConfigManager, () -> Void) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)
        let name = "iris-688-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (store, state, engine, ConfigManager(store: defaults), {
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func job() -> Job {
        var policy = JobPolicy()
        policy.grants = JobGrant(mounts: [ContainerMount(source: "/w", target: "/w", readOnly: false)], network: false)
        return Job(name: "tidy", prompt: "", trigger: .schedule(.interval(seconds: 600)), profile: .mutating,
                   policy: policy, action: .script(spec))
    }

    /// The surveys, in call order: before, then after.
    private func runner(_ store: ConversationStore, _ state: AppState, _ engine: IrisEngine, _ config: ConfigManager,
                        surveys: [MountSurvey], free: Int64 = 50 * 1_073_741_824, ran: Locked<Int>) -> JobRunner {
        let queue = Locked(surveys)
        return JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                         protectionEnabled: false,
                         scriptRunner: { _, _ in ran.mutate { $0 += 1 }; return .ran(stdout: "tidied 3\n", stderr: "", exitCode: 0) },
                         fingerprintCheck: { _, _, _, _ in .matches },
                         mountSurveyor: { _ in queue.mutate { $0.isEmpty ? MountSurvey(entries: 0, bytes: 0, repositories: [], capped: true) : $0.removeFirst() } },
                         freeSpace: { _ in free },
                         scriptLineGuard: { ($0, false) })
    }

    private let clean = MountSurvey(entries: 100, bytes: 1_000, repositories: [], capped: false)

    @Test("a repository in a read-write mount refuses the fire before the script runs")
    func repositoryRefuses() async throws {
        let (store, state, engine, config, teardown) = try harness(); defer { teardown() }
        let job = job(); try store.ledger.upsert(job)
        let ran = Locked(0)
        let r = runner(store, state, engine, config,
                       surveys: [MountSurvey(entries: 5, bytes: 0, repositories: ["/w/app"], capped: false)], ran: ran)
        _ = await r.fire(job: job, origin: .cadence(kind: "schedule"))
        #expect(ran.value == 0)
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .failed && run.failureReason == GateEvaluator.writingScriptRepositoryRefusal("/w/app"))
    }

    @Test("under the disk floor the fire is interrupted and the script never runs")
    func floorInterrupts() async throws {
        let (store, state, engine, config, teardown) = try harness(); defer { teardown() }
        let job = job(); try store.ledger.upsert(job)
        let ran = Locked(0)
        let r = runner(store, state, engine, config, surveys: [clean], free: 1_073_741_824, ran: ran)
        _ = await r.fire(job: job, origin: .cadence(kind: "schedule"))
        #expect(ran.value == 0)
        #expect(try store.ledger.runs(jobId: job.id, limit: 1).first?.status == .interrupted)
    }

    @Test("a run that makes a repository fails and pauses the job, naming it; the figures are on the row")
    func madeRepositoryPauses() async throws {
        let (store, state, engine, config, teardown) = try harness(); defer { teardown() }
        let job = job(); try store.ledger.upsert(job)
        let ran = Locked(0)
        let after = MountSurvey(entries: 101, bytes: 1_000, repositories: ["/w/new"], capped: false)
        let r = runner(store, state, engine, config, surveys: [clean, after], ran: ran)
        _ = await r.fire(job: job, origin: .cadence(kind: "schedule"))
        #expect(ran.value == 1)
        // The pause writes a row of its own after the run's; the run's is the one with figures.
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 5).first { $0.mountFigures != nil })
        #expect(run.status == .failed && run.failureReason?.contains("/w/new") == true)
        #expect(run.mountFigures == [MountFigures(source: "/w", before: clean, after: after)])
        #expect(try store.ledger.jobs().first?.pausedReason?.contains("/w/new") == true)
    }

    @Test("a run that leaves a mount too large to walk fails and pauses the job (#739 review)")
    func cappedAfterWalkFailsClosed() async throws {
        let (store, state, engine, config, teardown) = try harness(); defer { teardown() }
        let job = job(); try store.ledger.upsert(job)
        let ran = Locked(0)
        let capped = MountSurvey(entries: 200_000, bytes: 1_000, repositories: [], capped: true)
        let r = runner(store, state, engine, config, surveys: [clean, capped], ran: ran)
        _ = await r.fire(job: job, origin: .cadence(kind: "schedule"))
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 5).first { $0.mountFigures != nil })
        #expect(run.status == .failed && run.failureReason?.contains("couldn't finish checking") == true)
        #expect(try store.ledger.jobs().first?.pausedReason?.contains("couldn't finish checking") == true)
    }

    @Test("a run that empties a mount completes but pauses the job; an ordinary run doesn't")
    func lossPauses() async throws {
        let (store, state, engine, config, teardown) = try harness(); defer { teardown() }
        let job = job(); try store.ledger.upsert(job)
        let ran = Locked(0)
        let emptied = MountSurvey(entries: 10, bytes: 100, repositories: [], capped: false)
        let r = runner(store, state, engine, config, surveys: [clean, clean, MountSurvey(entries: 5_000, bytes: 1_000, repositories: [], capped: false), emptied], ran: ran)
        _ = await r.fire(job: job, origin: .cadence(kind: "schedule"))
        #expect(try store.ledger.jobs().first?.pausedReason == nil, "an ordinary run")
        _ = await r.fire(job: job, origin: .cadence(kind: "schedule"))
        let runs = try store.ledger.runs(jobId: job.id, limit: 5).filter { $0.mountFigures != nil }
        #expect(runs.count == 2 && runs.first?.status == .completed, "the emptying run itself completed")
        #expect(try store.ledger.jobs().first?.pausedReason?.contains("removed") == true)
    }
}
