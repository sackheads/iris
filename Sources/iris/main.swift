import Foundation

// Headless modes run before any SwiftUI window is created and exit. Top-level `await` runs this
// on the main actor, so the @MainActor entry points can execute directly.
if let perf = PerfCLI.parse(CommandLine.arguments) {
    switch perf {
    case .success(let cmd):
        exit(await PerfCLI.execute(cmd))
    case .failure(let err):
        FileHandle.standardError.write(Data("iris --perf: \(err.localizedDescription)\n\(PerfCLI.usage)\n".utf8))
        exit(64)
    }
} else if let benchOptions = BenchCLI.parse(CommandLine.arguments) {
    await BenchCLI.run(benchOptions)
    exit(0)
} else {
    IrisApp.main()
}
