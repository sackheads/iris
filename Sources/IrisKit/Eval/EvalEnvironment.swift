import Darwin
import Foundation
import IOKit.ps

/// What a result records about the machine and the code (spec, section 4). A field that can't be
/// read is left absent, never guessed.
enum EvalEnvironment {
    static func capture(repoRoot: URL) async -> EvalResult.Environment {
        let git = await gitState(repoRoot)
        return .init(chip: sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model"),
                     memoryBytes: sysctlInt("hw.memsize"),
                     macos: ProcessInfo.processInfo.operatingSystemVersionString,
                     onBattery: onBattery(),
                     irisCommit: git?.commit, irisDirty: git?.dirty)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    /// Whether the Mac is running on battery, which slows a run: flagged, not refused.
    static func onBattery() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
        return type == kIOPSBatteryPowerValue
    }

    /// The checkout's commit and whether it has changes. Our own repository, read with a bare
    /// environment; nil when git isn't there or the root isn't a checkout.
    static func gitState(_ root: URL) async -> (commit: String, dirty: Bool)? {
        func git(_ args: [String]) async -> String? {
            let result = await ProcessGroupRunner.capture(executable: "/usr/bin/git", arguments: ["-C", root.path] + args,
                                                          environment: ["PATH": "/usr/bin:/bin"], timeoutSeconds: 10)
            guard case .success(let out) = result, out.status == 0 else { return nil }
            return String(decoding: out.stdout, as: UTF8.self)
        }
        guard let head = await git(["rev-parse", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty,
              let status = await git(["status", "--porcelain", "--untracked-files=no"]) else { return nil }
        return (head, !status.isEmpty)
    }

    /// `phys_footprint` in MB, what Activity Monitor shows as Memory (#725's probe method).
    static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }
}
