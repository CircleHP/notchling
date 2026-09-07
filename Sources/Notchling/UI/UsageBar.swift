//
//  Plan limits along the bottom of the panel: two windows per agent, as numbers.
//
//  Bars cost a row apiece, and two windows for each of two agents is four rows on a panel whose whole
//  point is being glanceable. The numbers say the same thing in one line each. The meters stay where
//  they earn their space — inside a session row, where the context fill is a fraction nobody reads as
//  a number.
//
//  One line per agent, never one line for both. These are separate accounts on separate plans against
//  separate windows: two of them do not add up to one number, and a line that appeared to cover both
//  would be wrong in whichever direction it leaned.
//

import SwiftUI

struct UsageLines: View {
    let usage: [Provider: UsageSnapshot]

    @Environment(\.widgetMetrics) private var metrics

    /// A fixed order, so a line does not move when the other agent starts or stops reporting.
    private var lines: [(provider: Provider, snapshot: UsageSnapshot)] {
        [Provider.claude, .codex].compactMap { provider in
            usage[provider].map { (provider, $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.size(4)) {
            ForEach(lines, id: \.provider) { line in
                UsageLine(provider: line.provider, snapshot: line.snapshot)
            }
        }
    }
}

private struct UsageLine: View {
    let provider: Provider
    let snapshot: UsageSnapshot

    @Environment(\.widgetMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.size(8)) {
            Text(provider.displayName)
                .font(metrics.font(9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)

            Spacer(minLength: metrics.size(4))

            if let fiveHour = snapshot.fiveHour {
                UsageValue(label: "5h", window: fiveHour, isStale: snapshot.isStale)
            }
            if let sevenDay = snapshot.sevenDay {
                UsageValue(label: "7d", window: sevenDay, isStale: snapshot.isStale)
            }
        }
        .opacity(snapshot.isStale ? Theme.staleOpacity : 1)
    }
}

private struct UsageValue: View {
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
        HStack(spacing: metrics.size(3)) {
            Text(label)
                .font(metrics.font(9.5, design: .rounded))
                .foregroundStyle(Theme.dim)
            Text(value)
                .font(metrics.font(9.5, weight: .medium, design: .rounded))
                .foregroundStyle(isStale ? Theme.dim : tint)
                .monospacedDigit()
        }
        .lineLimit(1)
        .help(helpText)
    }

    private var value: String {
        // A window whose reset time has passed is not "0% left" — it is a fresh window nothing has
        // reported yet, because no session has spoken since it rolled over.
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
            parts.append(
                "Last refreshed when a session reported it — these numbers only move while a session is running."
            )
        }
        return parts.joined(separator: "\n")
    }
}
