import Testing
import Foundation
@testable import IrisKit

/// #1270 removed `isOwner: Bool = true` from `AppState.requestApproval`, `PermissionManager.isAllowed`/
/// `match`, and `ReadOnlyCommand.vibecopGate` -- the same footgun class as #1237/#1240/#1289's finding:
/// a caller that forgot to resolve a binding used to silently read as owner. A source scan pins the
/// absence, the same pattern as `SubagentManagerBindingWiringSourceScanTests`: a regression here would
/// not fail any existing assertion (every current call site already passes an explicit value), so
/// nothing but a scan catches the default creeping back in.
@Suite("isOwner default regression source scan (#1270)")
struct IsOwnerDefaultSourceScanTests {
    private static let files = [
        "Sources/IrisKit/AppState.swift",
        "Sources/IrisKit/PermissionManager.swift",
        "Sources/IrisKit/ReadOnlyCommand.swift",
    ]

    @Test("isOwner is never defaulted on the approval/permission boundary functions")
    func noOwnerDefaultReappears() throws {
        for path in Self.files {
            let url = PerfPaths.repoRoot().appendingPathComponent(path)
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(!source.contains("isOwner: Bool = true"),
                    "\(path): isOwner must never default to true -- a forgotten binding resolution would silently read as owner")
        }
    }

    /// A literal `isOwner: true`, or `isOwner: self.binding.isOwner` (the #1237 lesson: the
    /// engine's own principal is not the turn's binding), are exactly the mistakes this scan must
    /// catch -- so it asserts the positive form each call must have, not just the absence of one
    /// bad spelling. Also asserts a non-zero count: an empty match set would pass this vacuously.
    ///
    /// Two forms count as compliant: `isOwner: await callIsOwner(...)` (the real production call
    /// sites in iris.swift), and `isOwner: isOwner)` -- the bare parameter name, which is only
    /// `AppState.requestApproval`'s own one-line passthrough to `requestApprovalSource`. That
    /// parameter has no default (pinned by `noOwnerDefaultReappears` above) and is itself audited
    /// at every one of `requestApproval`'s own call sites, all of which are tests today.
    @Test("every requestApprovalSource call resolves isOwner through the turn's own binding")
    func everyCallUsesCallIsOwner() throws {
        var totalCalls = 0
        for path in ["Sources/IrisKit/AppState.swift", "Sources/IrisKit/iris.swift"] {
            let url = PerfPaths.repoRoot().appendingPathComponent(path)
            let source = try String(contentsOf: url, encoding: .utf8)
            var searchRange = source.startIndex..<source.endIndex
            while let callRange = source.range(of: "requestApprovalSource(", range: searchRange) {
                let openIndex = source.index(before: callRange.upperBound)
                let callEnd = Self.matchingParen(in: source, openingAt: openIndex)
                let call = source[callRange.lowerBound..<callEnd]
                let lineStart = source[source.startIndex..<callRange.lowerBound].lastIndex(of: "\n").map(source.index(after:)) ?? source.startIndex
                let linePrefix = source[lineStart..<callRange.lowerBound]
                if linePrefix.contains("func ") { searchRange = callEnd..<source.endIndex; continue }
                totalCalls += 1
                #expect(call.contains("isOwner: await callIsOwner(") || call.contains("isOwner: isOwner)"),
                        "\(path): requestApprovalSource must resolve isOwner via callIsOwner(conversationId) (or AppState.requestApproval's own audited passthrough) -- not a literal true or self.binding.isOwner")
                searchRange = callEnd..<source.endIndex
            }
        }
        #expect(totalCalls >= 5, "expected at least the 5 known production call sites -- a count of 0 would pass the check above vacuously")
    }

    /// Finds the index just past the parenthesis matching the one at `openIndex` (which must point at `(`).
    private static func matchingParen(in source: String, openingAt openIndex: String.Index) -> String.Index {
        var depth = 0
        var i = openIndex
        while i < source.endIndex {
            if source[i] == "(" { depth += 1 }
            else if source[i] == ")" {
                depth -= 1
                if depth == 0 { return source.index(after: i) }
            }
            i = source.index(after: i)
        }
        return source.endIndex
    }
}
