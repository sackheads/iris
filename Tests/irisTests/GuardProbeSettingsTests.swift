import Foundation
import Testing
@testable import IrisKit

/// #1006: a fully overridden local `--guard-probe` must not read the Keychain secrets item.
@Suite("guard-probe settings steps (#1006)")
struct GuardProbeSettingsTests {
    private func options(_ args: [String]) throws -> GuardProbeCLI.Options {
        try #require(try GuardProbeCLI.parse(["iris", "--guard-probe"] + args)?.get())
    }

    private func steps(_ o: GuardProbeCLI.Options) -> [String] {
        var steps: [String] = []
        GuardProbeCLI.prepareSettings(o, requestBypass: { steps.append("bypass") }, useVolatile: { steps.append("volatile") })
        return steps
    }

    @Test("engine, model and tier 2 all given, local engine: the bypass is asked for before the volatile copy")
    func fullyOverriddenLocal() throws {
        for engine in ["mlx", "llama_cpp", "ollama"] {
            let o = try options(["--engine", engine, "--model", "some-model", "--tier2", "none"])
            #expect(!GuardProbeCLI.needsHomeSecrets(o), "\(engine)")
            #expect(steps(o) == ["bypass", "volatile"], "\(engine)")
        }
    }

    @Test("a partial override reads the rest of the home's config: no bypass")
    func partialOverride() throws {
        for args in [["--engine", "mlx"], ["--model", "m"], ["--tier2", "none"],
                     ["--engine", "mlx", "--model", "m"], ["--engine", "mlx", "--tier2", "none"], ["--model", "m", "--tier2", "none"]] {
            let o = try options(args)
            #expect(GuardProbeCLI.needsHomeSecrets(o), "\(args)")
            #expect(steps(o) == ["volatile"], "\(args)")
        }
    }

    @Test("a cloud engine needs the home's key: no bypass even when fully overridden")
    func cloudEngine() throws {
        let o = try options(["--engine", "cloud", "--model", "gemini-3-flash", "--tier2", "none"])
        #expect(GuardProbeCLI.needsHomeSecrets(o))
        #expect(steps(o) == ["volatile"])
    }

    @Test("no override at all is the home's own settings: neither step runs")
    func noOverride() throws {
        let o = try options([])
        #expect(GuardProbeCLI.needsHomeSecrets(o))
        #expect(steps(o) == [])
    }

    @Test("run goes through prepareSettings, before ConfigManager.shared is first touched")
    func runCallsItFirst() throws {
        let source = try String(contentsOf: PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/GuardProbeCLI.swift"), encoding: .utf8)
        let call = try #require(source.range(of: "prepareSettings(options, requestBypass: { KeychainManager.requestHeadlessBypass() }"))
        let shared = try #require(source.range(of: "let config = ConfigManager.shared"))
        #expect(call.lowerBound < shared.lowerBound, "the bypass must be requested before the secrets item is read")
        #expect(!source.contains("if options.overridesConfig { IrisDefaults.useVolatileCopyOfStandard() }"),
                "the old unconditional volatile copy must not come back as a second path")
    }
}
