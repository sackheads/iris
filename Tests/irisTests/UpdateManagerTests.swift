import Testing
import Foundation
@testable import IrisKit

@Suite("UpdateManager Tests")
struct UpdateManagerTests {

    @Test("isVersionNewer correctly identifies newer semantic versions")
    func testIsVersionNewer() {
        #expect(UpdateManager.isVersionNewer(current: "0.1.0", latest: "v0.2.0") == true)
        #expect(UpdateManager.isVersionNewer(current: "0.1.0", latest: "0.1.1") == true)
        #expect(UpdateManager.isVersionNewer(current: "1.0.0", latest: "2.0.0") == true)
        #expect(UpdateManager.isVersionNewer(current: "0.2.0", latest: "0.1.0") == false)
        #expect(UpdateManager.isVersionNewer(current: "0.1.0", latest: "0.1.0") == false)
        #expect(UpdateManager.isVersionNewer(current: "v1.2.3", latest: "v1.2.3") == false)
    }

    @Test("ReleaseInfo decodes GitHub API JSON payload correctly")
    func testReleaseInfoDecoding() throws {
        let json = """
        {
            "tag_name": "v0.2.0",
            "name": "Iris 0.2.0 Release",
            "body": "Awesome new features!",
            "html_url": "https://github.com/bnaylor/iris/releases/tag/v0.2.0",
            "assets": [
                {
                    "name": "Iris-v0.2.0-macOS.zip",
                    "browser_download_url": "https://github.com/bnaylor/iris/releases/download/v0.2.0/Iris-v0.2.0-macOS.zip"
                }
            ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(ReleaseInfo.self, from: json)
        #expect(release.tagName == "v0.2.0")
        #expect(release.name == "Iris 0.2.0 Release")
        #expect(release.htmlUrl == "https://github.com/bnaylor/iris/releases/tag/v0.2.0")
        #expect(release.downloadUrl == "https://github.com/bnaylor/iris/releases/download/v0.2.0/Iris-v0.2.0-macOS.zip")
    }
}
