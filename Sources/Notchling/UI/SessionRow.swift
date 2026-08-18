//
//  One session in the panel, and the small pieces it is built from. Every row is a button that focuses
//  the terminal tab that owns the session.
//

import SwiftUI

struct SessionRow: View {
    let session: Session
    let onFocus: (Session) -> Void

    @Environment(\.widgetMetrics) private var metrics
    @State private var isHovering = false

    var body: some View {
        Button { onFocus(session) } label: {
            HStack(alignment: .top, spacing: metrics.size(8)) {
                StateDot(state: session.state)
                    .padding(.top, metrics.size(3))

                VStack(alignment: .leading, spacing: metrics.size(1)) {
                    titleLine
                    if let activity = session.activityLine() {
                        Text(activity)
                            .font(metrics.font(10.5))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let metrics = session.metrics, !metrics.isStale {
                        MetricsLine(metrics: metrics)
                    }
                }

                Spacer(minLength: metrics.size(6))

                trailing
                    .frame(minWidth: metrics.size(58), alignment: .trailing)
            }
            .padding(.vertical, metrics.size(5))
            .padding(.horizontal, metrics.size(7))
            .background {
                RoundedRectangle(cornerRadius: metrics.size(7))
                    .fill(isHovering ? Theme.surface : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
    }

    private var titleLine: some View {
        HStack(spacing: metrics.size(5)) {
            Text(session.displayName)
                .font(metrics.font(12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)

            if session.kind == .bg {
                Tag(text: "bg")
            }
        }
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: metrics.size(1)) {
            Text(session.isStalled ? "stalled" : Theme.label(for: session.state))
                .font(metrics.font(9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(session.isStalled ? Theme.amber : Theme.color(for: session.state))

            // Re-renders once a second while a turn is in flight, and not at all otherwise.
            if session.state == .working, let start = session.turnStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date.timeIntervalSince(start).elapsedLabel)
                        .font(metrics.font(9.5, design: .rounded))
                        .foregroundStyle(session.isStalled ? Theme.amber.opacity(0.8) : Theme.dim)
                        .monospacedDigit()
                }
            } else if let agents = session.agentSummary {
                // Ahead of the tool tally, which during a fan-out is just `Agent` — while this says how
                // many agents are out and how many are back. The working branch above puts the same fact
                // in the activity line, where the elapsed timer is not competing for the space.
                Text(agents)
                    .font(metrics.font(9.5, design: .rounded))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            } else if let tally = session.toolTally, session.state != .idle {
                Text(tally)
                    .font(metrics.font(9.5, design: .rounded))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
        }
    }

    private var helpText: String {
        var parts: [String] = []
        if let cwd = session.cwd { parts.append(cwd) }
        // From `UserPromptSubmit`. Nothing else in the hook stream says what a session was asked to
        // do, and the row itself only has space for what it is doing *now*.
        if let prompt = session.lastPrompt, !prompt.isEmpty {
            let trimmed = prompt.count > 160 ? String(prompt.prefix(160)) + "…" : prompt
            parts.append("Task: \(trimmed)")
        }
        if session.isStalled, let stalled = session.stalledFor() {
            if let tool = session.currentTool, let usual = session.currentToolUsualDuration {
                parts.append(
                    "\(tool) has been running \(stalled.elapsedLabel); "
                        + "the slowest it has managed here is \(usual.elapsedLabel)."
                )
            } else {
                parts.append("No tool activity for \(stalled.elapsedLabel).")
            }
        }
        if let metrics = session.metrics {
            if let context = metrics.contextUsedPercent {
                let window = metrics.contextWindowLabel.map { " of \($0)" } ?? ""
                parts.append("Context \(Int(context.rounded()))% used\(window)")
            }
            if let added = metrics.linesAdded, let removed = metrics.linesRemoved, added + removed > 0 {
                parts.append("+\(added) −\(removed) lines this session")
            }
        }
        if TerminalFocus.canFocusPrecisely(session) {
            parts.append("Click to focus its tab")
        } else {
            parts.append("Click to activate its app (no tab-level focus available)")
        }
        return parts.joined(separator: "\n")
    }
}

/// Context fill and model — the things only the status line knows.
private struct MetricsLine: View {
    let metrics: SessionMetrics

    @Environment(\.widgetMetrics) private var widget

    /// Coloured by how *full* the context is: this only becomes interesting near the top, so it rests
    /// at `dim` rather than competing with the state dot on the same row.
    private var contextTint: Color {
        Theme.fillTint(usedFraction: (metrics.contextUsedPercent ?? 0) / 100, resting: Theme.dim)
    }

    var body: some View {
        HStack(spacing: widget.size(5)) {
            if let context = metrics.contextUsedPercent {
                SegmentedMeter(fraction: context / 100, tint: contextTint, segments: 6, gap: widget.size(1.5))
                    .frame(width: widget.size(34), height: widget.size(4))
                Text("\(Int(context.rounded()))%")
                    .foregroundStyle(contextTint)
                    .monospacedDigit()
            }
            if let model = metrics.model {
                Text(model)
            }
        }
        .font(widget.font(9, weight: .medium, design: .rounded))
        .foregroundStyle(Theme.dim)
        .lineLimit(1)
    }
}

private struct StateDot: View {
    let state: SessionState

    @Environment(\.widgetMetrics) private var metrics

    var body: some View {
        Circle()
            .fill(Theme.color(for: state))
            .frame(width: metrics.size(6), height: metrics.size(6))
            .overlay {
                // A ring on the states that want attention, so they stay distinguishable without
                // relying on colour alone.
                if state == .needsYou || state == .error {
                    Circle()
                        .stroke(
                            Theme.color(for: state).opacity(Theme.attentionRingOpacity),
                            lineWidth: metrics.size(3)
                        )
                        .frame(width: metrics.size(11), height: metrics.size(11))
                }
            }
    }
}

private struct Tag: View {
    let text: String

    @Environment(\.widgetMetrics) private var metrics

    var body: some View {
        Text(text)
            .font(metrics.font(8.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, metrics.size(4))
            .padding(.vertical, metrics.size(1))
            .background {
                Capsule().fill(Theme.surface)
            }
    }
}
