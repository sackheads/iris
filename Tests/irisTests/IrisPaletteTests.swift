import SwiftUI
import Testing
@testable import IrisKit

/// #277: what reads on a dark window is not what reads on a light one.
@Suite("Iris palette across appearances")
struct IrisPaletteTests {
    @Test func darkLooksAreTheOnesThatShippedBefore() {
        #expect(IrisPalette.ledWell(.dark) == Color.black.opacity(0.30))
        #expect(IrisPalette.ledEdge(.dark) == Color.white.opacity(0.10))
        #expect(IrisPalette.bubbleFaintOpacity(.dark) == 0.55)
        #expect(IrisPalette.spectrumOpacity(.dark) == 0.7)
        #expect(IrisPalette.buttonFill(enabled: false, .dark) == Color.irisIndigo.opacity(0.4))
    }

    @Test func lightWindowGetsALighterWellAndADarkEdge() {
        #expect(IrisPalette.ledWell(.light) == Color.black.opacity(0.07))
        #expect(IrisPalette.ledEdge(.light) == Color.black.opacity(0.12))
    }

    @Test func lightWindowKeepsWhiteTextReadable() {
        // White text sits on the bubble and on a disabled fill: a paler fill than the dark one
        // would lose it.
        #expect(IrisPalette.bubbleFaintOpacity(.light) > IrisPalette.bubbleFaintOpacity(.dark))
        #expect(IrisPalette.buttonFill(enabled: false, .light) == Color.irisIndigo.opacity(0.6))
        #expect(IrisPalette.buttonFill(enabled: true, .light) == Color.irisIndigo)
        #expect(IrisPalette.spectrumOpacity(.light) == 1)
    }

    @Test func unlitLEDIsMoreOpaqueOnALightAppearance() throws {
        let off = NSColor(IrisPalette.ledOff)
        func alpha(_ name: NSAppearance.Name) throws -> CGFloat {
            let appearance = try #require(NSAppearance(named: name))
            var a: CGFloat = 0
            appearance.performAsCurrentDrawingAppearance { a = off.usingColorSpace(.sRGB)?.alphaComponent ?? 0 }
            return a
        }
        #expect(try alpha(.aqua) > alpha(.darkAqua))
    }
}
