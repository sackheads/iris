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
} else if let invocation = RunJobCLI.parse(arguments: CommandLine.arguments) {
    // The real store and the real model client (#187 §8): a `--run-job` measurement is only worth
    // anything if it is the run the scheduler would have done. No volatile defaults and no
    // `HeadlessMode` for the same reason — approvals have to fail closed exactly as unattended.
    // The store is opened inside `run`, after the lock is checked, so a refused run never touches
    // it; `exit` here means no scheduler, no watchers and no window ever start.
    exit(await RunJobCLI.run(invocation,
                             store: try ConversationStore.onDisk(at: IrisPaths.default.conversationsDB),
                             client: LLMClient()))
} else {
    IrisApp.main()
}
