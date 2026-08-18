//
//  One subagent, indented under the session that spawned it.
//
//  A reduced `SessionRow`: one line, smaller type, no metrics and no name of its own — an agent has no cwd,
//  no context meter and no terminal. Clicking it focuses its session's tab, because that is the only place
//  it could take you.
//

import SwiftUI

struct AgentRow: View {
    let agent: SubagentActivity
    /// Closes the block, so the glyph turns a corner instead of continuing.
    let isLast: Bool
    let onFocus: () -> Void

    @Environment(\.widgetMetrics) private var metrics
    @State private var isHovering = false

    var body: some View {
        Button(action: onFocus) {
            HStack(spacing: metrics.size(6)) {
                AgentBranch(isLast: isLast, verticalBleed: metrics.size(3))

                Circle()
                    .fill(Theme.color(for: agent.state))
                    .frame(width: metrics.size(4), height: metrics.size(4))

                Text(agent.agentType ?? "agent")
                    .font(metrics.font(10, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if let activity = agent.activityLine {
                    Text(activity)
                        .font(metrics.font(10))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: metrics.size(4))

                trailing
            }
            .padding(.vertical, metrics.size(2))
            .padding(.trailing, metrics.size(7))
            .padding(.leading, metrics.size(Self.indent))
            .background {
                RoundedRectangle(cornerRadius: metrics.size(6))
                    .fill(isHovering ? Theme.surface : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
    }

    /// Enough to read as subordinate without pushing the text into the middle of the panel.
    static let indent: CGFloat = 16

    /// A finished agent shows nothing here: its result is already in the activity line, and repeating
    /// `done` beside it would spend the row's only spare space saying the same thing twice.
    @ViewBuilder
    private var trailing: some View {
        if agent.isFinished {
            EmptyView()
        } else if agent.state == .needsYou {
            Text(Theme.label(for: agent.state))
                .font(metrics.font(9, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.color(for: agent.state))
        } else {
            // Re-renders once a second, and only while this agent is actually running.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(agent.elapsed(now: context.date).elapsedLabel)
                    .font(metrics.font(9, design: .rounded))
                    .foregroundStyle(Theme.dim)
                    .monospacedDigit()
            }
        }
    }

    private var helpText: String {
        var parts: [String] = []
        if let type = agent.agentType { parts.append("\(type) subagent") }
        if let tally = agent.toolTally { parts.append(tally) }
        if let message = agent.lastMessage, !message.isEmpty {
            let trimmed = message.count > 160 ? String(message.prefix(160)) + "…" : message
            parts.append("Result: \(trimmed)")
        }
        parts.append("Click to focus the session that spawned it")
        return parts.joined(separator: "\n")
    }
}

/// The agents of one session that did not fit. Never the only thing shown about a fan-out — the session's
/// own line carries the count either way.
struct AgentOverflowRow: View {
    let count: Int

    @Environment(\.widgetMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.size(6)) {
            AgentBranch(isLast: true, verticalBleed: metrics.size(3))
            Text("\(count) more agent\(count == 1 ? "" : "s")")
                .font(metrics.font(9.5, design: .rounded))
                .foregroundStyle(Theme.dim)
            Spacer(minLength: 0)
        }
        .padding(.vertical, metrics.size(2))
        .padding(.leading, metrics.size(AgentRow.indent))
        .padding(.trailing, metrics.size(7))
    }
}

/// `├` or `└`, drawn rather than typed: the box-drawing glyphs sit on the text baseline and cannot be
/// centred on a row whose height is set by a smaller font.
private struct AgentBranch: View {
    let isLast: Bool
    /// Cancels the row's own vertical padding *and* half the gap the enclosing `VStack` puts between rows,
    /// so the spine is continuous rather than a column of disconnected ticks.
    let verticalBleed: CGFloat

    @Environment(\.widgetMetrics) private var metrics

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let x = size.width / 2
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: isLast ? size.height / 2 : size.height))
            path.move(to: CGPoint(x: x, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(Theme.hairline), lineWidth: metrics.size(1))
        }
        .frame(width: metrics.size(7))
        .padding(.vertical, -verticalBleed)
    }
}
