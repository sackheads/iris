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

    @Test("requestApprovalSource is never called with a literal isOwner: true in production code")
    func noLiteralTrueOnRequestApprovalSource() throws {
        for path in ["Sources/IrisKit/AppState.swift", "Sources/IrisKit/iris.swift"] {
            let url = PerfPaths.repoRoot().appendingPathComponent(path)
            let source = try String(contentsOf: url, encoding: .utf8)
            var searchRange = source.startIndex..<source.endIndex
            while let callRange = source.range(of: "requestApprovalSource(", range: searchRange) {
                let openIndex = source.index(before: callRange.upperBound)
                let callEnd = Self.matchingParen(in: source, openingAt: openIndex)
                let call = source[callRange.lowerBound..<callEnd]
                #expect(!call.contains("isOwner: true"),
                        "\(path): requestApprovalSource must be called with the turn's real binding (callIsOwner(conversationId)/bindingForCall), never a literal isOwner: true")
                searchRange = callEnd..<source.endIndex
            }
        }
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
