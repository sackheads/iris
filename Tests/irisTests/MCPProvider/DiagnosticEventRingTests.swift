import Testing
import Foundation
@testable import IrisKit

@Suite("DiagnosticEventRing")
struct DiagnosticEventRingTests {
    @Test("the ring drops the oldest entry once it exceeds capacity")
    func dropsOldestPastCapacity() {
        let ring = DiagnosticEventRing()
        for i in 0..<(DiagnosticEventRing.capacity + 10) {
            ring.record(.composerAcceptsFirstMouse(i.isMultiple(of: 2)))
        }
        let entries = ring.snapshot()
        #expect(entries.count == DiagnosticEventRing.capacity)
    }

    @Test("entries come back in the exact order they were recorded, synchronously")
    func preservesRecordingOrder() {
        let ring = DiagnosticEventRing()
        ring.record(.transcriptMouseDown(atWindowPoint: .zero))
        ring.record(.transcriptFocusHop(tookFocus: true))
        ring.record(.composerAcceptsFirstMouse(true))
        let events = ring.snapshot().map(\.event)
        #expect(events.count == 3)
        guard events.count == 3 else { return }
        switch events[0] {
        case .transcriptMouseDown: break
        default: Issue.record("expected transcriptMouseDown first")
        }
        switch events[1] {
        case .transcriptFocusHop(let tookFocus): #expect(tookFocus)
        default: Issue.record("expected transcriptFocusHop second")
        }
        switch events[2] {
        case .composerAcceptsFirstMouse(let value): #expect(value)
        default: Issue.record("expected composerAcceptsFirstMouse third")
        }
    }

    @Test("the oldest entries are the ones dropped, not an arbitrary subset")
    func dropsAreOldestFirst() {
        let ring = DiagnosticEventRing()
        for i in 0..<(DiagnosticEventRing.capacity + 5) {
            ring.record(.windowAppearanceChanged(name: "\(i)"))
        }
        let names = ring.snapshot().compactMap { entry -> String? in
            if case .windowAppearanceChanged(let name) = entry.event { return name }
            return nil
        }
        #expect(names.first == "5")
        #expect(names.last == "\(DiagnosticEventRing.capacity + 4)")
    }

    @Test("every DiagnosticEventRing.Event case has at least one production record( call site")
    func everyEventCaseHasAProductionCallSite() throws {
        let cases = [
            "transcriptMouseDown", "transcriptFocusHop", "composerAcceptsFirstMouse",
            "windowAppearanceChanged", "composerAppearanceChanged",
        ]
        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var foundCases: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for caseName in cases where text.contains("record(.\(caseName)") {
                foundCases.insert(caseName)
            }
        }
        let missing = Set(cases).subtracting(foundCases)
        #expect(missing.isEmpty, "no production record( call site found for: \(missing.sorted())")
    }
}
