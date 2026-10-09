import Foundation
import KeyboardShortcuts
import Testing
@testable import IrisKit

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

    @Test("a bundle-less process persists to the dev domain, never the legacy process-name one (#447)")
    func bundlelessDomain() {
        #expect(IrisDefaults.appDomain(bundleIdentifier: nil) == "com.bnaylor.iris.dev")
        #expect(IrisDefaults.appDomain(bundleIdentifier: nil) != AppDefaultsImport.legacyDomain)
        #expect(IrisDefaults.bundlelessSuiteName(bundleIdentifier: nil) == "com.bnaylor.iris.dev")
    }

    @Test("bundled apps keep their own domains and their .standard store")
    func bundledDomains() {
        #expect(IrisDefaults.appDomain(bundleIdentifier: "com.bnaylor.iris") == "com.bnaylor.iris")
        #expect(IrisDefaults.appDomain(bundleIdentifier: "com.bnaylor.iris.dev") == "com.bnaylor.iris.dev")
        #expect(IrisDefaults.bundlelessSuiteName(bundleIdentifier: "com.bnaylor.iris") == nil)
        #expect(IrisDefaults.bundlelessSuiteName(bundleIdentifier: "com.bnaylor.iris.dev") == nil)
    }

    @Test("standard follows the identity; release is always ~/.iris")
    func standardAndRelease() {
        let real = FileManager.default.homeDirectoryForCurrentUser
        #expect(IrisPaths.release.root.path == real.appendingPathComponent(".iris").path)
        #expect(IrisPaths.standard.root.path == real.appendingPathComponent(".iris-dev").path)
    }
}
