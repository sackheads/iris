import Foundation
import KeyboardShortcuts
import Testing
@testable import iris

@Suite("Build identity")
struct BuildIdentityTests {
    @Test("only the exact release bundle id is release")
    func resolution() {
        #expect(BuildIdentity.resolve(bundleIdentifier: "com.bnaylor.iris") == .release)
        #expect(BuildIdentity.resolve(bundleIdentifier: nil) == .dev)
        #expect(BuildIdentity.resolve(bundleIdentifier: "com.bnaylor.iris.dev") == .dev)
        #expect(BuildIdentity.resolve(bundleIdentifier: "com.bnaylor.IRIS") == .dev)
        #expect(BuildIdentity.resolve(bundleIdentifier: "com.apple.dt.xctest.tool") == .dev)
    }

    @Test("the test process is a dev build")
    func testsAreDev() {
        #expect(BuildIdentity.current == .dev)
    }

    @Test("each identity has its own home, Keychain suffix and hotkey")
    func scopedValues() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(IrisPaths.home(for: .release, homeDirectory: home).root.path == "/Users/someone/.iris")
        #expect(IrisPaths.home(for: .dev, homeDirectory: home).root.path == "/Users/someone/.iris-dev")
        #expect(BuildIdentity.release.keychainServiceSuffix == "")
        #expect(BuildIdentity.dev.keychainServiceSuffix == ".dev")
        #expect(BuildIdentity.release.hotkeyName != BuildIdentity.dev.hotkeyName)
        #expect(BuildIdentity.release.defaultHotkey != BuildIdentity.dev.defaultHotkey)
    }

    @Test("standard follows the identity; release is always ~/.iris")
    func standardAndRelease() {
        let real = FileManager.default.homeDirectoryForCurrentUser
        #expect(IrisPaths.release.root.path == real.appendingPathComponent(".iris").path)
        #expect(IrisPaths.standard.root.path == real.appendingPathComponent(".iris-dev").path)
    }
}
