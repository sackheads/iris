import Testing
import Foundation
@testable import iris

@Suite("PerfEnvironment capture")
struct PerfEnvironmentTests {
    @Test("git sha comes from the repo")
    func gitSha() {
        let sha = PerfEnvironment.git(["rev-parse", "--short", "HEAD"], in: PerfPaths.repoRoot())
        #expect((sha?.count ?? 0) >= 7)
        #expect(sha?.allSatisfy(\.isHexDigit) == true)
    }

    @Test("machine model is non-empty")
    func machine() {
        #expect(!PerfEnvironment.machineModel().isEmpty)
    }

    @MainActor
    @Test("capture reflects the running configuration without mutating it")
    func capture() {
        let env = PerfEnvironment.capture(headless: true, toolDeclarationCount: 3, repoRoot: PerfPaths.repoRoot())
        #expect(env.provider == ConfigManager.shared.primaryProvider)
        #expect(env.models["medium"] == ConfigManager.shared.getModel(for: .medium))
        #expect(env.headless == true)
        #expect(env.toolDeclarationCount == 3)
        #expect(env.cpuCount == ProcessInfo.processInfo.activeProcessorCount)
        #expect(["debug", "release"].contains(env.buildConfiguration))
    }
}
