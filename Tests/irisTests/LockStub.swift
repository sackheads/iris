import Foundation
import Darwin
import Testing

/// Another process holding `flock(LOCK_EX)` on a file: the stand-in for another Iris (spec §3).
/// perl because it is on every Mac and its `flock` is flock(2). `$|=1`, or "ok" waits in perl's
/// buffer behind the pipe and `start` times out (plan note 7).
final class LockStub {
    enum StubError: Error { case perlMissing, notReady }

    let process: Process
    var pid: Int32 { process.processIdentifier }

    private init(process: Process) { self.process = process }

    /// Returns once the stub holds the lock. `payload`, when given, is written into the locked
    /// file first, with every `%PID%` replaced by the stub's own pid; nil leaves the file empty.
    static func start(holding url: URL, payload: String? = nil, within seconds: Double = 10) throws -> LockStub {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else { throw StubError.perlMissing }
        let script = #"""
        use Fcntl qw(:flock); use IO::Handle; $|=1;
        open(F, ">>", $ARGV[0]) or die "open: $!";
        flock(F, LOCK_EX) or die "flock: $!";
        if (defined $ARGV[1]) { my $p = $ARGV[1]; $p =~ s/%PID%/$$/g; truncate(F, 0); print F $p; F->flush(); }
        print "ok\n";
        sleep 60;
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", script, url.path] + (payload.map { [$0] } ?? [])
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let ready = DispatchSemaphore(value: 0)
        let seen = LockedCell(Data())
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            seen.value.append(chunk)   // one handler call at a time
            if seen.value.range(of: Data("ok\n".utf8)) != nil { ready.signal() }
        }
        try process.run()
        guard ready.wait(timeout: .now() + seconds) == .success else {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = Self.waitForExit(process)
            throw StubError.notReady
        }
        out.fileHandleForReading.readabilityHandler = nil
        return LockStub(process: process)
    }

    /// SIGKILL, the death no handler sees, and wait for it, for up to 10 s: the kernel has dropped
    /// the lock on return. Bounded, so a lost termination fails the test instead of hanging it.
    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(pid, SIGKILL)
        if !Self.waitForExit(process) {
            Issue.record("LockStub pid \(pid) still running 10 s after SIGKILL")
        }
    }

    /// Up to 10 s for `process` to be reaped. False when it is still running.
    private static func waitForExit(_ process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        return !process.isRunning
    }

    deinit { kill() }

    /// Asks a fresh process for `LOCK_EX | LOCK_NB` on `url`: 0 when it got the lock, 3 when the
    /// lock is held elsewhere, 2 when the file would not open. Never blocks.
    static func tryLock(_ url: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", #"use Fcntl qw(:flock); open(F, ">>", $ARGV[0]) or exit 2; flock(F, LOCK_EX | LOCK_NB) ? exit 0 : exit 3"#, url.path]
        do { try process.run() } catch { return 2 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// A mutable cell a `@Sendable` seam or handler can write and the test can read.
final class LockedCell<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
