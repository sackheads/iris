import Testing
import Foundation
@testable import IrisKit

/// #872: a grant given as `/private/tmp/x` is stored as `/tmp/x` (`IrisPaths.canonicalPath` strips
/// `/private`), and a call spelled the way `realpath` prints it must meet it. Each refusal row asks the
/// layer that refuses it (the spelling in `relativeComponents`, the real path in `covering`, the mode in
/// `allowedMount`), so a row cannot pass on another layer's rule.
@Suite("A grant under /private is met by either spelling (#872)", .timeLimit(.minutes(1)))
struct GrantPrivateSpellingTests {
    struct Fixture {
        let base: URL, mount: URL, outside: URL
        func tearDown() { try? FileManager.default.removeItem(at: base) }
        /// The grant as a person gives it: the /private spelling, stored as the product stores it.
        func grant(readOnly: Bool = false) -> JobGrant {
            JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath("/private/tmp/" + base.lastPathComponent + "/X"), readOnly: readOnly)])
        }
        var short: String { "/tmp/" + base.lastPathComponent + "/X" }
        var long: String { "/private" + short }
    }

    /// Made under /private/tmp with a root of its own.
    private func fixture() throws -> Fixture {
        let base = URL(fileURLWithPath: "/private/tmp/iris872-\(UUID().uuidString)")
        let mount = base.appendingPathComponent("X"), outside = base.appendingPathComponent("Y")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "x".write(to: mount.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        try "y".write(to: outside.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        return Fixture(base: base, mount: mount, outside: outside)
    }

    @Test func theStoredSpellingMapsWholeComponentsOnly() {
        #expect(JobGrant.storedSpelling("/private/tmp/x/f") == "/tmp/x/f")
        #expect(JobGrant.storedSpelling("/private/var/folders/a") == "/var/folders/a")
        #expect(JobGrant.storedSpelling("/private/etc") == "/etc")
        for unchanged in ["/privatefoo/tmp/x", "/private/varx/y", "/private/tmpx", "/private", "/private/", "/private/other/x", "/tmp/x", "private/tmp/x", "/Private/tmp/x", "/x/private/tmp"] {
            #expect(JobGrant.storedSpelling(unchanged) == unchanged, "\(unchanged)")
        }
    }

    @Test func eitherSpellingOfAGrantUnderPrivateTmpIsAllowed() throws {
        let f = try fixture(); defer { f.tearDown() }
        let g = f.grant()
        #expect(g.mounts[0].source == f.short, "stored without /private")
        for spelled in [f.long + "/f", f.short + "/f"] {
            #expect(g.allowedMount(toolName: "read_file", details: spelled, cwd: nil)?.source == f.short, "read \(spelled)")
            #expect(g.allowedMount(toolName: "write_file", details: spelled, cwd: nil)?.source == f.short, "write \(spelled)")
            #expect(g.allows(toolName: "write_file", details: spelled, cwd: nil, sandboxed: false))
        }
        // A file not yet created, and the mount itself, through the long spelling.
        #expect(g.allowedMount(toolName: "write_file", details: f.long + "/new/dir/out.md", cwd: nil) != nil)
        #expect(g.allowedMount(toolName: "read_file", details: f.long, cwd: nil) != nil)
        #expect(g.relativeComponents(of: f.long + "/a/./b", cwd: nil, under: g.mounts[0]) == ["a", "b"])
    }

    @Test func aDotDotStillRefusesAtTheSpellingLayer() throws {
        let f = try fixture(); defer { f.tearDown() }
        let g = f.grant()
        let target = f.long + "/../Y/f"
        #expect(g.relativeComponents(of: target, cwd: nil, under: g.mounts[0]) == nil, "the .. refusal")
        #expect(g.allowedMount(toolName: "read_file", details: target, cwd: nil) == nil)
    }

    @Test func aLinkOutOfTheMountStillRefusesAtTheRealPathLayer() throws {
        let f = try fixture(); defer { f.tearDown() }
        let g = f.grant()
        try FileManager.default.createSymbolicLink(atPath: f.mount.appendingPathComponent("out").path, withDestinationPath: f.outside.path)
        let target = f.long + "/out/f"
        // The spelling is under the mount, so the spelling layer allows; it is `covering` that refuses.
        #expect(g.relativeComponents(of: target, cwd: nil, under: g.mounts[0]) != nil)
        let real = try #require(IrisPaths.realPathForAllow(target))
        #expect(g.covering(real) == nil, "the link resolves outside the grant")
        #expect(g.allowedMount(toolName: "read_file", details: target, cwd: nil) == nil)
        #expect(g.allowedMount(toolName: "write_file", details: target, cwd: nil) == nil)
    }

    @Test func aNeighbouringSpellingIsNotMapped() throws {
        let f = try fixture(); defer { f.tearDown() }
        let g = f.grant()
        let name = f.base.lastPathComponent
        for spelled in ["/privatefoo/tmp/\(name)/X/f", "/private/tmpx/\(name)/X/f", "/private/varx/\(name)/X/f"] {
            #expect(g.relativeComponents(of: spelled, cwd: nil, under: g.mounts[0]) == nil, "spelling layer: \(spelled)")
            #expect(g.allowedMount(toolName: "read_file", details: spelled, cwd: nil) == nil)
        }
    }

    @Test func aReadOnlyGrantStillRefusesAWriteAtTheModeLayer() throws {
        let f = try fixture(); defer { f.tearDown() }
        let g = f.grant(readOnly: true)
        let target = f.long + "/f"
        let real = try #require(IrisPaths.realPathForAllow(target))
        #expect(g.covering(real) != nil && g.relativeComponents(of: target, cwd: nil, under: g.mounts[0]) != nil, "the spelling and the real path both allow")
        #expect(g.allowedMount(toolName: "read_file", details: target, cwd: nil) != nil)
        #expect(g.allowedMount(toolName: "write_file", details: target, cwd: nil) == nil, "the mode refuses")
    }

    @Test func theWalkIsHandedTheSameComponentsEitherWay() throws {
        let f = try fixture(); defer { f.tearDown() }
        let g = f.grant()
        let mount = try #require(g.allowedMount(toolName: "write_file", details: f.long + "/g", cwd: nil))
        let relative = try #require(g.relativeComponents(of: f.long + "/g", cwd: nil, under: mount))
        #expect(relative == ["g"], "the walk descends from the stored root, as it does for the short spelling")
    }
}
