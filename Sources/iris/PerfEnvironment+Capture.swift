import Foundation

extension PerfEnvironment {
    @MainActor
    static func capture(headless: Bool, toolDeclarationCount: Int?, repoRoot: URL, toolSandbox: String? = nil) -> PerfEnvironment {
        let config = ConfigManager.shared
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        return PerfEnvironment(
            gitSha: git(["rev-parse", "--short", "HEAD"], in: repoRoot) ?? "unknown",
            // Exclude perf/baselines: --promote writes an untracked baseline file earlier in the
            // same run, and that alone must not flag later suites in the run as dirty.
            gitDirty: !(git(["status", "--porcelain", "--", ".", ":(exclude)perf/baselines"], in: repoRoot) ?? "").isEmpty,
            machineModel: machineModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            cpuCount: ProcessInfo.processInfo.activeProcessorCount,
            buildConfiguration: build,
            provider: config.primaryProvider,
            models: Dictionary(uniqueKeysWithValues: ModelTier.allCases.map { ($0.rawValue, config.getModel(for: $0)) }),
            vibecopEnabled: config.enableVibecop,
            vibecopEngine: config.vibecopEngine,
            injectionGuardEnabled: config.enableAdvancedPromptInjectionProtection,
            promptGuardEngine: config.promptGuardEngine,
            sandboxEnabled: config.enableSandboxing,
            headless: headless,
            toolDeclarationCount: toolDeclarationCount,
            toolSandbox: toolSandbox,
            streaming: config.streamResponses)
    }

    /// Run git in `root` and return trimmed stdout; nil if git is missing or exits non-zero.
    static func git(_ args: [String], in root: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
