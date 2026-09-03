import Foundation

// Headless benchmark mode: when invoked with `--bench`, run a scenario through the core with no
// UI and exit, before any SwiftUI window is created. Otherwise launch the normal app.
// Top-level `await` runs this on the main actor, so the @MainActor bench can execute directly.
if let benchOptions = BenchCLI.parse(CommandLine.arguments) {
    await BenchCLI.run(benchOptions)
    exit(0)
} else {
    IrisApp.main()
}
