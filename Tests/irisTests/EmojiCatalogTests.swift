import Testing
import Foundation
@testable import IrisKit

@Suite("EmojiCatalog")
struct EmojiCatalogTests {
    let catalog = EmojiCatalog.shared

    @Test("dataset loads the full set")
    func loads() {
        #expect(catalog.items.count > 1900)
    }

    @Test("basic shortcode resolves")
    func wave() {
        #expect(catalog.glyph(for: "wave") == "👋")
    }

    @Test("aliases resolve to the same glyph")
    func aliases() {
        #expect(catalog.glyph(for: "thumbsup") == "👍")
        #expect(catalog.glyph(for: "+1") == catalog.glyph(for: "thumbsup"))
    }

    @Test("prefix search ranks exact first and respects the cap")
    func search() {
        let r = catalog.matches(prefix: "smi", limit: 5)
        #expect(r.count <= 5)
        #expect(r.contains { $0.shortcode == "smile" })
        #expect(catalog.matches(prefix: "smile", limit: 5).first?.shortcode == "smile")
    }

    @Test("skin tone applies to a capable emoji")
    func tone() {
        #expect(catalog.glyph(for: "wave", tone: .medium) == "👋🏽")
    }

    @Test("skin tone is ignored on a non-capable emoji")
    func toneIgnored() {
        #expect(catalog.glyph(for: "rocket", tone: .dark) == "🚀")
    }

    @Test("unknown shortcode returns nil")
    func unknown() {
        #expect(catalog.glyph(for: "definitelynotacode") == nil)
    }

    @Test("SkinTone modifier round-trips")
    func modifier() {
        #expect(SkinTone.fromModifier("skin-tone-4") == .medium)
        #expect(SkinTone.fromModifier("skin-tone-1") == nil)
        #expect(SkinTone.fromModifier("nonsense") == nil)
    }

    @Test("missing or invalid URL handles gracefully without crash")
    func invalidUrl() {
        let missingCatalog = EmojiCatalog(url: nil)
        #expect(missingCatalog.items.isEmpty)

        let bogusCatalog = EmojiCatalog(url: URL(fileURLWithPath: "/nonexistent/emoji.json"))
        #expect(bogusCatalog.items.isEmpty)
    }
}
