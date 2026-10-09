import Foundation
import Cocoa
import CryptoKit

final class SandboxingManager: @unchecked Sendable {
    static let shared = SandboxingManager()

    static let containerSearchPaths: [String] = [
        "/usr/local/bin/container",     // Default installer location
        "/opt/homebrew/bin/container",  // Homebrew on Apple Silicon
    ]

    /// Where to find the `container` binary. Injected so a test can point this manager at a stub
    /// binary (one that sleeps forever, or overruns a pipe) instead of searching the real machine
    /// (#293 review).
    private let binaryPath: @Sendable () -> String?
    /// How long `startContainerSystem` gives `container system start` before killing it and
    /// answering `false`. Generous by default: a first start after a reboot or reinstall can
    /// download and install the default kernel, which takes minutes, not seconds. Injected so a
    /// test can force the timeout branch without waiting out the real default.
    private let startTimeoutSeconds: Double

    init(binaryPath: @escaping @Sendable () -> String? = SandboxingManager.resolveBinaryPath,
         startTimeoutSeconds: Double = 120) {
        self.binaryPath = binaryPath
        self.startTimeoutSeconds = startTimeoutSeconds
    }

    static func resolveBinaryPath() -> String? {
        containerSearchPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The first existing container binary path, or nil if not installed.
    var containerBinaryPath: String? { binaryPath() }

    var isContainerInstalled: Bool {
        containerBinaryPath != nil
    }
    
    func installContainer(completion: @escaping @MainActor (Bool, String?) -> Void) {
        Task {
            do {
                // Fetch the latest release pkg
                let urlString = "https://github.com/apple/container/releases/download/1.1.0/container-1.1.0-installer-signed.pkg"
                guard let url = URL(string: urlString) else {
                    await completion(false, "Invalid URL")
                    return
                }
                
                let pkgPath = "/tmp/container-installer.pkg"
                let (data, _) = try await URLSession.shared.data(from: url)
                
                let expectedHash = "0ca1c42a2269c2557efb1d82b1b38ac553e6a3a3da1b1179c439bcee1e7d6714"
                let actualHash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                
                guard actualHash == expectedHash else {
                    await completion(false, "Security Error: Downloaded PKG hash mismatch. Expected: \(expectedHash), Got: \(actualHash)")
                    return
                }
                
                try data.write(to: URL(fileURLWithPath: pkgPath))
                
                // We use AppleScript to prompt for privileges to install the PKG
                let scriptSource = """
                do shell script "installer -pkg /tmp/container-installer.pkg -target / && echo 'y' | /usr/local/bin/container system start" with administrator privileges
                """
                
                var error: NSDictionary?
                if let script = NSAppleScript(source: scriptSource) {
                    _ = script.executeAndReturnError(&error)
                    await MainActor.run {
                        if error != nil {
                            completion(false, "Installation failed or was cancelled.")
                        } else {
                            completion(true, nil)
                        }
                    }
                } else {
                    await completion(false, "Failed to create AppleScript.")
                }
            } catch {
                await completion(false, error.localizedDescription)
            }
        }
    }
    
    /// One `container system start` at a time: a second caller while one is already running joins
    /// it rather than spawning its own (#293 review) — two concurrent starts is the one case where
    /// the auto-approved kernel download ("y") would run twice at once.
    private let lock = NSLock()
    private var inFlightStart: Task<(success: Bool, message: String?), Never>?

    /// Starts the container system daemon and automatically approves the kernel image download
    /// ("y"). Bounded by `startTimeoutSeconds`: a `container system start` stuck waiting on
    /// launchd, or on a slow kernel download, answers `false` rather than hanging the caller
    /// forever — this now sits on JobRunner's fire-time pre-check and click-time re-check, both
    /// ahead of a run's own deadline, and a hang there would wedge the job `inFlight` for good
    /// (#293 review).
    @discardableResult
    func startContainerSystem() async -> (success: Bool, message: String?) {
        guard let binaryPath = containerBinaryPath else {
            return (false, "Apple container runtime is not installed.")
        }
        let task: Task<(success: Bool, message: String?), Never> = lock.withLock {
            if let existing = inFlightStart { return existing }
            let t = Task {
                let result = await Self.runStart(binaryPath: binaryPath, timeoutSeconds: self.startTimeoutSeconds)
                // Cleared from inside the task itself, once its own result is in hand: `Task`
                // has no identity to compare against from outside, and this runs exactly once
                // per start regardless of how many callers joined it.
                self.lock.withLock { self.inFlightStart = nil }
                return result
            }
            inFlightStart = t
            return t
        }
        return await task.value
    }

    /// `container system start`, through `ProcessGroupRunner` rather than `sh -c`: no shell to
    /// splice an unquoted path into, and the pipes drain as the process runs (not after
    /// `waitUntilExit`), so progress output from a kernel download cannot overrun the pipe buffer
    /// and deadlock the start (#293 review).
    private static func runStart(binaryPath: String, timeoutSeconds: Double) async -> (success: Bool, message: String?) {
        let result = await ProcessGroupRunner.capture(executable: binaryPath, arguments: ["system", "start"],
                                                       environment: nil, stdin: Data("y\n".utf8), mergeStderr: true,
                                                       timeoutSeconds: timeoutSeconds)
        switch result {
        case .success(let output):
            if output.timedOut {
                return (false, "container system start did not finish within \(Int(timeoutSeconds)) seconds")
            }
            guard output.status == 0 else {
                let text = String(data: output.stdout, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (false, text.isEmpty ? "container system start exited with status \(output.status)" : text)
            }
            return (true, nil)
        case .failure(let error):
            return (false, error.localizedDescription)
        }
    }
}
