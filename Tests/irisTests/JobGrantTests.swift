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
