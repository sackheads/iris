import Foundation
import SwiftUI

@Observable
@MainActor
class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()
    
    var isDownloading = false
    var progress: Double = 0.0
    var error: String? = nil
    var currentDownloadName: String? = nil
    
    private var downloadTask: URLSessionDownloadTask?
    
    // Some known models and their URLs for convenience
    let knownModels = [
        "Qwen3.5-2B-Q4_K_M.gguf": "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf",
        "gemma-4-E2B-it-Q4_K_M.gguf": "https://huggingface.co/bartowski/google_gemma-4-E2B-it-GGUF/resolve/main/google_gemma-4-E2B-it-Q4_K_M.gguf",
        "gemma-4-12B-it-Q4_K_M.gguf": "https://huggingface.co/bartowski/gemma-4-12B-it-GGUF/resolve/main/gemma-4-12B-it-Q4_K_M.gguf"
    ]

    // Approximate on-disk sizes for known models, for UI download prompts.
    let knownModelSizes = [
        "Qwen3.5-2B-Q4_K_M.gguf": "1.3GB",
        "gemma-4-E2B-it-Q4_K_M.gguf": "3.1GB",
        "gemma-4-12B-it-Q4_K_M.gguf": "7.4GB"
    ]

    /// Human-readable approximate download size for a model name, falling back
    /// to a range when the model is custom/unknown (e.g. a user-supplied URL).
    func approximateSize(for name: String) -> String {
        knownModelSizes[name] ?? "1–8GB"
    }
    
    /// Resolves a config value that may be a raw filename or a source URL to the file name it
    /// lives under in `modelsDir`. Shared with `InjectionGuard.tier3Provisioning` (#202) so the
    /// two checks can never disagree about what "downloaded" means.
    nonisolated static func resolvedFilename(for name: String) -> String {
        name.starts(with: "http") ? (URL(string: name)?.lastPathComponent ?? name) : name
    }

    /// Resolves a CoreML/ONNX guard-model config value (raw name, source URL, or `.zip` archive)
    /// to the directory name it unpacks to under `modelsDir`. Builds on `resolvedFilename` and
    /// additionally strips a trailing `.zip` — the tier-2 guard model ships as
    /// `<name>.onnx.zip`/`<name>.mlmodelc.zip` and unzips to `<name>.onnx/`/`<name>.mlmodelc/`.
    /// Shared by `CoreMLEvaluator.loadModelIfNeeded`, `InjectionGuard.tier2Provisioning` (#210),
    /// and `ModelLEDBar.tier2State` so none of them can drift on what "downloaded" means.
    nonisolated static func resolvedCoreMLDirectoryName(for name: String) -> String {
        let filename = resolvedFilename(for: name)
        return filename.hasSuffix(".zip") ? String(filename.dropLast(4)) : filename
    }

    func isModelDownloaded(name: String) -> Bool {
        let filename = Self.resolvedFilename(for: name)
        let path = IrisPaths.default.modelsDir.path + "/" + filename
        return FileManager.default.fileExists(atPath: path)
    }

    /// CoreML/ONNX-specific downloaded-check (#210 fix round 1). Guards the empty-name case —
    /// `isModelDownloaded(name: "")` resolves to `modelsDir.path` itself, which exists as soon as
    /// anything has ever been downloaded, so an unconfigured Tier 2 field showed "Model ready" in
    /// the Setup Wizard (`SettingsView` happened to guard this itself before calling in, but the
    /// Wizard did not). Resolves through `resolvedCoreMLDirectoryName` so Settings/Setup Wizard can
    /// never disagree with `InjectionGuard.tier2Provisioning`/`ModelLEDBar.tier2State` about what
    /// "downloaded" means. `isModelDownloaded` itself is left alone for its gguf/vibecop callers.
    func isCoreMLModelDownloaded(name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let dirName = Self.resolvedCoreMLDirectoryName(for: name)
        let path = IrisPaths.default.modelsDir.path + "/" + dirName
        return FileManager.default.fileExists(atPath: path)
    }
    
    /// Downloads (and unzips, if a `.zip`) a model into `~/.iris/models/`.
    ///
    /// When the caller passed a URL, the config field holding it usually needs to be
    /// rewritten to the resolved local filename so loaders can find it — but *which* field
    /// depends on the caller (the vibecop model, the Tier 3 canary, etc.), so the caller
    /// supplies it via `assignResolvedNameTo`. The Tier 2 guard passes `nil` because
    /// `CoreMLEvaluator` resolves the filename from the URL itself and the field should
    /// keep the URL for re-downloads.
    func downloadModel(name: String, assignResolvedNameTo keyPath: ReferenceWritableKeyPath<ConfigManager, String>? = nil) async {
        guard !isDownloading else { return }

        let isUrl = name.starts(with: "http")
        let urlString = knownModels[name] ?? (isUrl ? name : nil)

        guard let finalUrlString = urlString, let url = URL(string: finalUrlString), url.scheme != nil else {
            self.error = "Unknown model name. Please provide a full https:// URL to a .gguf file."
            return
        }

        let filename = isUrl ? url.lastPathComponent : name

        func assignResolvedName() {
            if isUrl, let keyPath { ConfigManager.shared[keyPath: keyPath] = filename }
        }

        guard !isModelDownloaded(name: filename) else {
            assignResolvedName()
            return
        }

        // Update the UI immediately so it shows the filename instead of the URL
        assignResolvedName()
        
        self.isDownloading = true
        self.progress = 0.0
        self.error = nil
        self.currentDownloadName = filename
        
        let dirPath = IrisPaths.default.modelsDir.path
        if !FileManager.default.fileExists(atPath: dirPath) {
            try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }

        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        
        let request = URLRequest(url: url)
        self.downloadTask = session.downloadTask(with: request)
        self.downloadTask?.taskDescription = filename
        self.downloadTask?.resume()
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let filename = downloadTask.taskDescription else { return }
        let dirPath = IrisPaths.default.modelsDir.path
        let destination = URL(fileURLWithPath: dirPath).appendingPathComponent(filename)
        
        do {
            if !FileManager.default.fileExists(atPath: dirPath) {
                try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            
            if filename.hasSuffix(".zip") {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", destination.path, "-d", dirPath]
                try process.run()
                process.waitUntilExit()
                try? FileManager.default.removeItem(at: destination) // clean up zip either way
                // #210 fix round 1: `unzip`'s exit status was never checked. A partial/failed
                // extraction (disk full, truncated download, corrupt archive) used to leave
                // whatever it managed to write sitting at the resolved directory path —
                // `InjectionGuard.tier2Provisioning`/`ModelLEDBar.tier2State` only check that the
                // directory *exists*, so that reported "provisioned" while the actual load kept
                // throwing on every guarded turn (the do/catch -> `.error`, fail-closed path),
                // uncached, with no notice pointing at why. Remove whatever the partial unzip left
                // behind and surface it the same way other download failures are surfaced below.
                guard process.terminationStatus == 0 else {
                    let unpackedName = ModelDownloader.resolvedCoreMLDirectoryName(for: filename)
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: dirPath).appendingPathComponent(unpackedName))
                    throw NSError(domain: "ModelDownloader", code: Int(process.terminationStatus), userInfo: [
                        NSLocalizedDescriptionKey: "unzip exited with status \(process.terminationStatus); the download was removed, please retry"
                    ])
                }
            }
            
            Task { @MainActor in
                self.progress = 1.0
                self.isDownloading = false
                self.currentDownloadName = nil
            }
        } catch {
            Task { @MainActor in
                self.error = "Download failed to save: \(error.localizedDescription)"
                self.isDownloading = false
                self.currentDownloadName = nil
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            if totalBytesExpectedToWrite > 0 {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error = error {
                self.error = "Download failed: \(error.localizedDescription)"
                self.isDownloading = false
                self.currentDownloadName = nil
            }
        }
    }
}
