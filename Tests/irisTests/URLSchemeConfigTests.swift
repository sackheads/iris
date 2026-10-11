import Testing
import Foundation
@testable import IrisKit

/// D6 decision 12: each build registers its own scheme, the one `BuildIdentity.urlScheme` says the
/// handler answers, so a release and a dev install never claim each other's links. Read from the
/// repo, located from `#filePath` and never the cwd.
@Suite("URL scheme configuration (D6)")
struct URLSchemeConfigTests {
    private func repoFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("the two identities answer different schemes")
    func identitiesDiffer() {
        #expect(BuildIdentity.release.urlScheme == "iris")
        #expect(BuildIdentity.dev.urlScheme == "iris-dev")
    }

    @Test("Debug sets iris-dev and Release sets iris, matching BuildIdentity")
    func projectSetsBothSchemes() throws {
        let yml = try repoFile("project.yml")
        let debug = try #require(yml.range(of: "Debug:"))
        let release = try #require(yml.range(of: "Release:"))
        let debugBlock = yml[debug.upperBound..<release.lowerBound]
        let releaseBlock = yml[release.upperBound...].prefix(400)
        // Whole lines, never substrings: "IRIS_URL_SCHEME: iris" is a prefix of "… iris-dev".
        func setting(_ block: Substring) -> [String] {
            block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("IRIS_URL_SCHEME:") }
        }
        #expect(setting(debugBlock) == ["IRIS_URL_SCHEME: \(BuildIdentity.dev.urlScheme)"])
        #expect(setting(releaseBlock) == ["IRIS_URL_SCHEME: \(BuildIdentity.release.urlScheme)"])
    }

    @Test("Info.plist registers exactly one scheme, from the build setting")
    func plistRegistersTheScheme() throws {
        let plist = try repoFile("App/Info.plist")
        let parsed = try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
        let types = try #require(parsed?["CFBundleURLTypes"] as? [[String: Any]])
        #expect(types.count == 1)
        #expect(types.first?["CFBundleURLSchemes"] as? [String] == ["$(IRIS_URL_SCHEME)"])
        #expect(types.first?["CFBundleURLName"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
    }
}
