import SwiftUI

/// The lines the status row shows for the loads in flight (#779): one per load, oldest first, at
/// most `maxLines`, then "+N more". Pure, so the wording is tested without a view.
enum ModelLoadStatus {
    static let maxLines = 3

    static func line(_ load: ModelLoad, nowMs: Double) -> String {
        let seconds = max(0, Int((nowMs - load.startedAtMs) / 1000))
        return "Loading \(load.purpose.label) model: \(load.name) [\(seconds)s]"
    }

    /// `active` is oldest first, as `ModelLoadTracker.active` returns it.
    static func lines(_ active: [ModelLoad], nowMs: Double) -> [String] {
        var lines = active.prefix(maxLines).map { line($0, nowMs: nowMs) }
        if active.count > maxLines { lines.append("+\(active.count - maxLines) more") }
        return lines
    }
}

/// A row directly above the LED bar while any local model loads (#779), so it shows with the LEDs
/// hidden too. Absent when nothing loads. It reads the tracker once a second, which also ticks
/// the seconds; a load that ends between ticks is gone by the next one. A failed load just
/// disappears: the LED and its notice report the error (#218).
struct ModelLoadStatusRow: View {
    var tracker: ModelLoadTracker = .shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let lines = ModelLoadStatus.lines(tracker.active, nowMs: MonotonicClock.nowMs())
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "hourglass")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                // In the composer stack: bounded (Invariant 8). Four caption lines at most.
                .frame(maxHeight: 72)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
