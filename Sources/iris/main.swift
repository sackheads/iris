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
    // The store is opened inside `run`, after the lock is claimed, so a refused run never touches
    // it; exiting here means no scheduler, no watchers and no window ever start.
    let code = await RunJobCLI.run(invocation,
                                   store: try ConversationStore.onDisk(at: IrisPaths.default.conversationsDB),
                                   client: LLMClient())
    // `_exit`, the way `AppDelegate` leaves at terminate: a blocked tool call asks Vibecop for a
    // verdict, which on the embedded engine loads ggml, and `exit`'s static destructors then trip
    // llama.cpp's `GGML_ASSERT` — so a script would read 134 for a run whose row says "blocked on
    // approval" and whose documented code is 2. This command's contract *is* its exit code.
    // Nothing is lost by skipping the atexit handlers: the run's save was flushed inside `run`,
    // the lock released by its `defer`, and the two streams are flushed here.
    fflush(stdout)
    fflush(stderr)
    _exit(code)
} else {
    IrisApp.main()
}
