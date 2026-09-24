import Testing
import Foundation
@testable import iris

/// #282 §1 — the model half of a grant: the mount struct and its string form, the grant, and its
/// lenient home inside `JobPolicy`. Pure codec behaviour; nothing here touches a disk or a runtime.
@Suite("JobGrant model (#282)")
struct JobGrantTests {
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("a mount round-trips through its string form, and the target is omitted when identity-mapped")
    func mountRoundTrips() throws {
        let rw = try ContainerMount(parsing: "/Users/me/proj")
        #expect(rw == ContainerMount(source: "/Users/me/proj"))
        #expect(rw.entry == "/Users/me/proj")
        #expect(!rw.readOnly && rw.target == "/Users/me/proj")

        let ro = try ContainerMount(parsing: "/Users/me/deploy-key:/gh:ro")
        #expect(ro == ContainerMount(source: "/Users/me/deploy-key", target: "/gh", readOnly: true))
        #expect(ro.entry == "/Users/me/deploy-key:/gh:ro")
        #expect(try ContainerMount(parsing: "/a:ro").entry == "/a:ro")

        // Codable IS the string: the policy JSON, the result and `/jobs` all show one spelling.
        #expect(try json([rw, ro]) == #"["\/Users\/me\/proj","\/Users\/me\/deploy-key:\/gh:ro"]"#)
        let back = try JSONDecoder().decode([ContainerMount].self, from: Data(#"["/a","/b:/c:ro"]"#.utf8))
        #expect(back == [ContainerMount(source: "/a"), ContainerMount(source: "/b", target: "/c", readOnly: true)])
    }

    @Test("parsing refuses what argument(for:) refuses, with the same reasons")
    func mountParsingRefusals() throws {
        for entry in ["", "/a:", "/a:/b:/c", "relative:/x", "/a,b", "/a:/b:rw"] {
            #expect(throws: ContainerRuntimeError.self, Comment(rawValue: entry)) {
                try ContainerMount(parsing: entry)
            }
        }
        #expect(throws: ContainerRuntimeError.invalidMount(entry: "data:/data", reason: "both paths must be absolute; a relative source is read as the name of a volume, not a directory")) {
            try ContainerMount(parsing: "data:/data")
        }
        // And the rendered argument is the one the runtime already tests.
        #expect(try ContainerMount(source: "/a", target: "/b", readOnly: true).argument
                == "type=virtiofs,source=/a,target=/b,readonly")
    }

    @Test("the working directory is the first read-write mount, or nil")
    func workingDirectory() {
        let grant = JobGrant(mounts: [ContainerMount(source: "/p"), ContainerMount(source: "/q", readOnly: true)])
        #expect(grant.workingDirectory == "/p")
        #expect(JobGrant(mounts: [ContainerMount(source: "/q", readOnly: true)]).workingDirectory == nil)
        #expect(JobGrant().workingDirectory == nil)
        #expect(grant.mountEntries == ["/p", "/q:ro"])
    }

    @Test("a grant decodes leniently: absent fields default, and network defaults to false")
    func grantDecodesLeniently() throws {
        let empty = try JSONDecoder().decode(JobGrant.self, from: Data("{}".utf8))
        #expect(empty == JobGrant())
        let mountsOnly = try JSONDecoder().decode(JobGrant.self, from: Data(#"{"mounts":["/p"]}"#.utf8))
        #expect(mountsOnly.network == false && mountsOnly.mounts == [ContainerMount(source: "/p")])
    }

    @Test("a policy carries its grant, and a policy without one encodes exactly as before")
    func policyCarriesGrant() throws {
        let grant = JobGrant(mounts: [ContainerMount(source: "/p"), ContainerMount(source: "/q", readOnly: true)], network: true)
        let policy = JobPolicy(overlap: .queue, grants: grant)
        let text = try json(policy)
        #expect(text.contains(#""grants":{"mounts":["\/p","\/q:ro"],"network":true}"#))
        #expect(try JSONDecoder().decode(JobPolicy.self, from: Data(text.utf8)) == policy)
        // Byte-for-byte the D3 shape for an ungranted job: no `grants` key at all.
        #expect(!(try json(JobPolicy())).contains("grants"))
    }

    @Test("a grant this build cannot read is nil, and the policy around it still decodes")
    func malformedGrantIsNilAndPolicySurvives() throws {
        let junk = try JSONDecoder().decode(JobPolicy.self, from: Data(#"{"overlap":"queue","grants":"junk"}"#.utf8))
        #expect(junk.grants == nil)
        #expect(junk.overlap == .queue, "the rest of the policy is not lost to the grant")
        let badMount = try JSONDecoder().decode(JobPolicy.self, from: Data(#"{"grants":{"mounts":["relative"]}}"#.utf8))
        #expect(badMount.grants == nil, "one unreadable mount drops the whole grant, never half of it")
    }

    @Test("a stored job with an unreadable grant still loads from the ledger, ungranted")
    func ledgerLoadsAJobWithAnUnreadableGrant() throws {
        let store = try ConversationStore.inMemory()
        let job = Job(name: "g", prompt: "p", trigger: .schedule(.interval(seconds: 60)), profile: .mutating)
        try store.ledger.upsert(job)
        try store.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET policy = ? WHERE id = ?",
                           arguments: [#"{"grants":{"mounts":[42]}}"#, job.id.uuidString])
        }
        let back = try #require(try store.ledger.job(id: job.id))
        #expect(back.policy.grants == nil)
        #expect(store.ledger.unreadableJobCount == 0)
    }
}

/// The creation half's pure core (#282 §1, §0.11): what `mounts`/`network` resolve to and every
/// refusal by name, against temp directories only.
@Suite("JobGrant.resolve (#282)")
struct JobGrantResolveTests {
    struct Fixture {
        let base: URL          // <tmp>/iris-grant-<uuid>
        let proj: URL          // base/proj
        let creds: URL         // base/creds
        let irisRoot: URL      // base/dot-iris  (contains config/)
        let home: String       // base/home
        var paths: IrisPaths { IrisPaths(root: irisRoot) }
        func tearDown() { try? FileManager.default.removeItem(at: base) }
    }

    static func fixture() throws -> Fixture {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("iris-grant-\(UUID().uuidString)")
        for name in ["proj", "creds", "dot-iris/config", "home"] {
            try fm.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        return Fixture(base: base, proj: base.appendingPathComponent("proj"),
                       creds: base.appendingPathComponent("creds"),
                       irisRoot: base.appendingPathComponent("dot-iris"),
                       home: base.appendingPathComponent("home").path)
    }

    private func resolve(_ f: Fixture, _ mounts: [String]?, network: Bool? = nil,
                         profile: JobProfile = .mutating) -> Result<JobGrant?, ToolMessage> {
        JobGrant.resolve(mounts: mounts, network: network, profile: profile,
                         paths: f.paths, home: f.home, isVolume: { _ in false })
    }

    private func canonical(_ url: URL) -> String { IrisPaths.canonicalPath(url.path) }

    @Test("a grant resolves with canonical sources, verbatim targets, and the first read-write as working directory")
    func resolvesCanonical() throws {
        let f = try Self.fixture(); defer { f.tearDown() }
        let grant = try #require(try resolve(f, [f.proj.path, "\(f.creds.path):/gh:ro"], network: true).get())
        #expect(grant.mounts == [ContainerMount(source: canonical(f.proj)),
                                 ContainerMount(source: canonical(f.creds), target: "/gh", readOnly: true)])
        #expect(grant.network == true)
        #expect(grant.workingDirectory == canonical(f.proj))
        // Naming neither is nothing granted, on either profile.
        #expect(try resolve(f, nil).get() == nil)
        #expect(try resolve(f, []).get() == nil)
        #expect(try resolve(f, nil, profile: .readOnly).get() == nil)
        // A network bit alone is a grant: commands may reach the network from a mount-less container.
        #expect(try resolve(f, nil, network: true).get() == JobGrant(mounts: [], network: true))
    }

    @Test("an explicit network: false with no mounts is a grant on a mutating job, and nothing on a read-only one (§0.11)")
    func explicitNetworkOffIsAGrant() throws {
        let f = try Self.fixture(); defer { f.tearDown() }
        let off = try #require(try resolve(f, [], network: false).get())
        #expect(off == JobGrant(mounts: [], network: false))
        #expect(off.sentence == "Grant: no mounts · network off.")
        #expect(try resolve(f, nil, network: false).get() == JobGrant(mounts: [], network: false))
        #expect(try resolve(f, nil, network: false, profile: .readOnly).get() == nil,
                "a read-only job asked for nothing it does not already have")
    }

    @Test("each refusal, by name, in the spec's order")
    func refusalsByName() throws {
        let f = try Self.fixture(); defer { f.tearDown() }
        func refusal(_ mounts: [String]?, network: Bool? = nil, profile: JobProfile = .mutating) -> String? {
            if case .failure(let m) = resolve(f, mounts, network: network, profile: profile) { return m.text }
            return nil
        }
        // 1. a grant on a read-only profile — mounts or network alike
        #expect(refusal([f.proj.path], profile: .readOnly) == JobGrant.grantNeedsMutating)
        #expect(refusal(nil, network: true, profile: .readOnly) == JobGrant.grantNeedsMutating)
        // 2. malformed, with ContainerMount's own reasons
        #expect(refusal(["relative/dir"])?.contains("both paths must be absolute") == true)
        #expect(refusal(["\(f.proj.path):/in,puts"])?.contains("comma") == true)
        #expect(refusal(["/a:/b:/c"])?.contains("expected source[:target][:ro]") == true)
        // 3. missing or a file
        let gone = "/tmp/\(UUID().uuidString)"
        #expect(refusal([gone]) == JobGrant.missing(gone))
        let file = f.base.appendingPathComponent("f.txt"); try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(refusal([file.path]) == JobGrant.notADirectory(canonical(file)))
        // 4. too broad: /, a volume root, a mount point, the home directory
        #expect(refusal(["/"]) == JobGrant.tooBroad("/"))
        // Refused whether or not such a volume is mounted: absent it is `missing`, mounted it is
        // the lexical `/Volumes/<x>` rule — either way nothing is granted.
        #expect(refusal(["/Volumes/Data"]) != nil)
        #expect(refusal([f.home]) == JobGrant.tooBroad(IrisPaths.canonicalPath(f.home)))
        let volume = JobGrant.resolve(mounts: [f.creds.path], network: nil, profile: .mutating,
                                      paths: f.paths, home: f.home, isVolume: { _ in true })
        #expect(volume == .failure(ToolMessage(JobGrant.tooBroad(canonical(f.creds)))))
        // 5. Iris's own directory, read-only included, in both directions
        #expect(refusal([f.irisRoot.path + ":ro"]) == JobGrant.protected(canonical(f.irisRoot)))
        #expect(refusal([f.irisRoot.appendingPathComponent("config").path]) == JobGrant.protected(canonical(f.irisRoot.appendingPathComponent("config"))))
        #expect(refusal([f.base.path]) == JobGrant.protected(canonical(f.base)), "a root that contains ~/.iris sees every write into it")
        // 6. a credential store, by name — see credentialStoresRefusedByName for the whole list
        try FileManager.default.createDirectory(atPath: f.home + "/.ssh", withIntermediateDirectories: true)
        #expect(refusal([f.home + "/.ssh:ro"]) == JobGrant.credentialStoreRefusal)
        // 7. read-only first, read-write after — and it outranks a duplicate further down the list
        #expect(refusal(["\(f.creds.path):ro", f.proj.path]) == JobGrant.readOnlyFirst)
        #expect(refusal(["\(f.creds.path):ro", f.proj.path, f.proj.path]) == JobGrant.readOnlyFirst)
        #expect(refusal(["\(f.creds.path):ro"]) == nil, "all read-only is fine: the working directory is /")
        // 8. the same source twice, however spelled
        #expect(refusal([f.proj.path, f.proj.path + "/"]) == JobGrant.duplicate(canonical(f.proj)))
    }

    @Test("every credential store is refused by name — itself, under it, and anything that contains it — read-only included; a sibling is not (§0.12)")
    func credentialStoresRefusedByName() throws {
        let f = try Self.fixture(); defer { f.tearDown() }
        let fm = FileManager.default
        for entry in JobGrant.credentialStores {
            let store = f.home + String(entry.dropFirst())            // "~/.ssh" → "<home>/.ssh"
            try fm.createDirectory(atPath: store + "/inner", withIntermediateDirectories: true)
            for spelled in [store, store + ":ro", store + "/inner", store + "/inner:/keys:ro"] {
                #expect(resolve(f, [spelled]) == .failure(ToolMessage(JobGrant.credentialStoreRefusal)), Comment(rawValue: spelled))
            }
        }
        #expect(JobGrant.credentialStores.count == 9, "the list the spec names, no more and no fewer")
        // Both directions, the `~/.iris` containment rule: a mount that holds a store hands it over
        // with everything around it. (The home directory itself is refused earlier, as too broad.)
        for parent in ["/.config", "/Library", "/Library/Application Support"] {
            for spelled in [f.home + parent, f.home + parent + ":ro"] {
                #expect(resolve(f, [spelled]) == .failure(ToolMessage(JobGrant.credentialStoreRefusal)), Comment(rawValue: spelled))
            }
        }
        try FileManager.default.createDirectory(atPath: f.home + "/Library/Application Support/SomeApp", withIntermediateDirectories: true)
        #expect(try resolve(f, [f.home + "/Library/Application Support/SomeApp"]).get() != nil,
                "a sibling under a refused parent that contains no store is fine")
        // A directory made for the job beside a store is what §0.2 asks for, and is fine.
        let sibling = f.home + "/.ssh-deploy-key"
        try fm.createDirectory(atPath: sibling, withIntermediateDirectories: true)
        #expect(try resolve(f, [sibling + ":ro"]).get()?.mounts.first?.source == IrisPaths.canonicalPath(sibling))
        // Matched on canonical paths: a symlink to a store is the store.
        let link = f.base.appendingPathComponent("keys")
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: f.home + "/.aws"))
        #expect(resolve(f, [link.path]) == .failure(ToolMessage(JobGrant.credentialStoreRefusal)))
    }

    @Test("nested entries are allowed and the sentence says so")
    func nestedEntries() throws {
        let f = try Self.fixture(); defer { f.tearDown() }
        let sub = f.proj.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let grant = try #require(try resolve(f, [f.proj.path, "\(sub.path):ro"]).get())
        #expect(grant.describe() == "read-write \(canonical(f.proj)) (working directory) · read-only \(canonical(sub)) · network off · nested: \(canonical(sub)) under \(canonical(f.proj)), whose mode applies beneath it")
        let plain = try #require(try resolve(f, [f.proj.path, "\(f.creds.path):/gh:ro"], network: true).get())
        #expect(plain.describe() == "read-write \(canonical(f.proj)) (working directory) · read-only \(canonical(f.creds)) → /gh · network on")
        #expect(plain.sentence == "Grant: \(plain.describe()).")
        #expect(JobGrant(network: true).describe() == "no mounts · network on")
    }

    @Test("the host-reachable note is the listing's only (§0.7): the result sentence says network off")
    func hostReachableOnlyOnTheListing() {
        let off = JobGrant(mounts: [ContainerMount(source: "/p")])
        #expect(off.describe() == "read-write /p (working directory) · network off")
        #expect(off.describe(hostNote: true) == "read-write /p (working directory) · network off (host reachable)")
        #expect(off.sentence == "Grant: read-write /p (working directory) · network off.")
        #expect(JobGrant(network: true).describe(hostNote: true) == "no mounts · network on")
    }
}
