import Testing
import Foundation
@testable import IrisKit

/// #492: every home names its containers with a prefix of its own, so a sweep from `~/.iris` never
/// reaches `~/.iris-dev`'s live containers, and the `--run-job` CLI can sweep too.
@Suite("Per-home container prefix")
struct ContainerPrefixTests {
    private let release = URL(fileURLWithPath: "/Users/x/.iris", isDirectory: true)
    private let dev = URL(fileURLWithPath: "/Users/x/.iris-dev", isDirectory: true)

    private func mgr(_ rt: MockRuntime, live: LiveContainerNames = LiveContainerNames()) -> SandboxSessionManager {
        SandboxSessionManager(runtime: rt, image: { "ubuntu:latest" }, live: live)
    }

    private var own: String { SandboxSessionManager.namePrefix }
    private func uuid() -> String { UUID().uuidString.lowercased() }

    @Test("a home's prefix is iris-h, 8 hex digits and a dash, and the same every time")
    func shape() {
        let p = SandboxSessionManager.containerPrefix(for: release)
        #expect(p.wholeMatch(of: /iris-h[0-9a-f]{8}-/) != nil, "got \(p)")
        #expect(SandboxSessionManager.containerPrefix(for: release) == p)
        #expect(SandboxSessionManager.containerPrefix(for: URL(fileURLWithPath: "/Users/x/.iris/")) == p,
                "a trailing slash is the same home")
    }

    @Test("two homes get prefixes neither of which starts the other")
    func distinct() {
        let a = SandboxSessionManager.containerPrefix(for: release)
        let b = SandboxSessionManager.containerPrefix(for: dev)
        #expect(a != b)
        #expect(!a.hasPrefix(b) && !b.hasPrefix(a))
    }

    @Test("this process's prefix is its home's")
    func processPrefix() {
        #expect(own == SandboxSessionManager.containerPrefix(for: IrisPaths.default.root))
    }

    @Test("the old shared names are recognised, and no new name is taken for one")
    func legacyShapes() {
        for name in ["iris-\(uuid())", "iris-gate-\(uuid())", "iris-hook-\(uuid())", "iris-run-\(uuid())"] {
            #expect(SandboxSessionManager.isLegacyName(name), "\(name)")
        }
        for name in ["\(own)\(uuid())", "\(own)gate-\(uuid())", "\(own)hook-\(uuid())", "\(own)run-\(uuid())",
                     "iris-isolated", "iris-orphan", "iris-gate-notauuid", "iristest-\(uuid())"] {
            #expect(!SandboxSessionManager.isLegacyName(name), "\(name)")
        }
    }

    @Test("a sweep takes only its own home's orphans")
    func sweepsOwnHomeOnly() async {
        let rt = MockRuntime()
        let mine = "\(own)\(uuid())"
        let other = "\(SandboxSessionManager.containerPrefix(for: dev))\(uuid())"
        let legacy = "iris-\(uuid())"
        rt.existing = [mine, other, legacy, "unrelated"]

        await mgr(rt).reapOrphans(inFlight: { [] }, includingLegacy: false)

        #expect(rt.removedNames == [mine])
    }

    @Test("with legacy names included, the old shapes go too, and still nothing of another home's")
    func sweepsLegacy() async {
        let rt = MockRuntime()
        let mine = "\(own)hook-\(uuid())"
        let other = "\(SandboxSessionManager.containerPrefix(for: dev))run-\(uuid())"
        let legacy = ["iris-\(uuid())", "iris-gate-\(uuid())", "iris-hook-\(uuid())", "iris-run-\(uuid())"]
        rt.existing = [mine, other, "iris-orphan"] + legacy

        await mgr(rt).reapOrphans(inFlight: { [] }, includingLegacy: true)

        #expect(Set(rt.removedNames) == Set([mine] + legacy))
    }

    @Test("only the release build sweeps the old names")
    func legacyIsReleaseOnly() {
        #expect(SandboxSessionManager.sweepsLegacyNames(.release))
        #expect(!SandboxSessionManager.sweepsLegacyNames(.dev))
    }

    /// A session container is recorded in `LiveContainerNames` before its create starts, but joins
    /// `sessions` only once the create returns. A sweep listing mid-create must not take it.
    @Test("a sweep spares a container this process recorded and is still creating")
    func sparesMidCreate() async {
        let rt = MockRuntime()
        let live = LiveContainerNames()
        let creating = "\(own)\(uuid())"
        let orphan = "\(own)\(uuid())"
        live.add(creating)
        rt.existing = [creating, orphan]

        await mgr(rt, live: live).reapOrphans(inFlight: { [] }, includingLegacy: false)

        #expect(rt.removedNames == [orphan])
    }
}
