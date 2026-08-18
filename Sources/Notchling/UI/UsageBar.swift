//
//  Plan rate limits at the bottom of the panel: how much of the 5-hour and 7-day windows is left, and
//  when each one resets.
//

import SwiftUI

struct UsageBarSection: View {
    let usage: UsageSnapshot

    @Environment(\.widgetMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.size(5)) {
            if let fiveHour = usage.fiveHour {
                UsageRow(label: "5h", window: fiveHour, isStale: usage.isStale)
            }
            if let sevenDay = usage.sevenDay {
                UsageRow(label: "7d", window: sevenDay, isStale: usage.isStale)
            }
        }
    }
}

private struct UsageRow: View {
    let label: String
    let window: UsageWindow
    let isStale: Bool

    @Environment(\.widgetMetrics) private var metrics

    /// A window whose reset time has passed is not "nearly out", it is unknown, so it goes grey.
    private var tint: Color {
        guard !window.hasReset else { return Theme.dim }
        return Theme.fillTint(usedFraction: window.usedPercentage / 100, resting: Theme.clay)
    }

    var body: some View {
        HStack(spacing: metrics.size(7)) {
            Text(label)
                .font(metrics.font(9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.dim)
                .frame(width: metrics.size(15), alignment: .leading)

            SegmentedMeter(fraction: window.usedPercentage / 100, tint: tint, gap: metrics.size(2))
                .frame(height: metrics.size(5))

            Text(rightLabel)
                .font(metrics.font(9.5, weight: .medium, design: .rounded))
                .foregroundStyle(isStale ? Theme.dim : tint)
                .monospacedDigit()
                .frame(width: metrics.size(108), alignment: .trailing)
        }
        .opacity(isStale ? Theme.staleOpacity : 1)
        .help(helpText)
    }

    private var rightLabel: String {
        // A window whose reset time has passed is not "0% left" — it is a fresh window we have not been
        // told about yet, because the status line has not run since it rolled over.
        if window.hasReset { return "reset · stale" }
        let remaining = "\(Int(window.remainingPercentage.rounded()))% left"
        guard let reset = window.resetLabel else { return remaining }
        return "\(remaining) · \(reset)"
    }

    private var helpText: String {
        var parts = ["\(Int(window.usedPercentage.rounded()))% of the \(label) limit used"]
        if let resetsAt = window.resetsAt {
            parts.append("resets \(resetsAt.formatted(date: .omitted, time: .shortened))")
        }
        if isStale {
            parts.append("Last refreshed when a session was on screen — these numbers only update while Claude Code is running.")
        }
        return parts.joined(separator: "\n")
    }
}
