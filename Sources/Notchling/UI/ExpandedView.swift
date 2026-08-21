//
//  The panel that drops out of the notch on hover: every live session, most urgent first, each row a
//  button that jumps to the terminal tab that owns it.
//

import SwiftUI

struct ExpandedView: View {
    /// Must match `SessionRow`'s own horizontal padding. A row pads itself so its hover highlight
    /// extends past the text, which means the row's *content* sits this far in; anything that does not
    /// repeat the same inset ends up on a different edge.
    static let contentInset: CGFloat = 7

    /// Unscaled. `WidgetPresenter` needs this before any view exists, to size the window — and
    /// `WidgetWindowGeometry` is a plain struct with no actor, which is why this says so explicitly.
    nonisolated static let panelWidth: CGFloat = 380

    let store: SessionStore
    let actions: WidgetActions

    /// Which rows the panel draws, captured when it opened.
    ///
    /// Row *contents* stay live — state, tool, elapsed all keep updating, and none of those change the
    /// panel's height. Only the row *count* is frozen, because `WidgetPresenter.contentGeometryChanged`
    /// deliberately refuses to resize the window while the panel is open: resizing moves it out from under
    /// a stationary pointer, AppKit recomputes hover, SwiftUI reports a spurious hover-off, and the panel
    /// collapses and re-expands in a loop, oscillating for as long as the pointer stays put. A session
    /// list changes row count rarely, so that costs nothing; a fan-out changes it every few seconds, which
    /// would make it constant — so agents appearing or finishing are shown on the next open.
    ///
    /// `WidgetView.showsPanel` rebuilds this view on every open, so the capture is current each time
    /// without any explicit invalidation.
    @State private var layout: PanelLayout

    /// Captured when the panel opens, for the same reason the row list is: `WidgetPresenter` refuses
    /// to resize the window while the panel is open, so a row appearing mid-hover would be drawn
    /// outside the space the window has. It appears on the next open instead.
    @State private var pendingVersion: String?

    @Environment(\.widgetMetrics) private var metrics

    init(
        store: SessionStore,
        actions: WidgetActions
    ) {
        self.store = store
        self.actions = actions
        _layout = State(initialValue: PanelLayout(sessions: store.sessions))
        _pendingVersion = State(initialValue: store.pendingVersion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.size(8)) {
            header

            if let version = pendingVersion {
                UpgradeNoticeRow(version: version, onRestart: actions.restart)
                    .padding(.horizontal, metrics.size(Self.contentInset))
            }

            if layout.rows.isEmpty {
                Text("No Claude sessions running")
                    .font(metrics.font(12))
                    .foregroundStyle(Theme.dim)
                    .padding(.vertical, metrics.size(6))
                    .padding(.horizontal, metrics.size(Self.contentInset))
            } else {
                VStack(spacing: metrics.size(2)) {
                    ForEach(Array(layout.rows.enumerated()), id: \.element.id) { index, row in
                        self.view(for: row, at: index)
                    }
                }
                if let summary = layout.summary {
                    Text(summary)
                        .font(metrics.font(10, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.dim)
                        .padding(.top, metrics.size(2))
                        .padding(.horizontal, metrics.size(Self.contentInset))
                }
            }

            if let usage = store.usage {
                Divider()
                    .overlay(Theme.hairline)
                    .padding(.vertical, metrics.size(1))
                    .padding(.horizontal, metrics.size(Self.contentInset))
                UsageBarSection(usage: usage)
                    .padding(.horizontal, metrics.size(Self.contentInset))
            }
        }
        .padding(.horizontal, metrics.size(4))
        .frame(width: metrics.size(Self.panelWidth), alignment: .leading)
    }

    /// Each row re-reads its own current state, falling back to what was captured when the panel opened.
    /// The fallback is what a session ending mid-hover hits: its row keeps its last known contents rather
    /// than vanishing, because vanishing is a height change.
    @ViewBuilder
    private func view(for row: PanelRow, at index: Int) -> some View {
        switch row {
        case let .session(captured):
            SessionRow(session: store.session(id: captured.sessionID) ?? captured, onFocus: actions.focus)

        case let .agent(sessionID, captured):
            AgentRow(
                agent: store.session(id: sessionID)?.agents[captured.agentID] ?? captured,
                isLast: layout.isLastInBlock(index),
                onFocus: {
                    guard let session = store.session(id: sessionID) else { return }
                    actions.focus(session)
                }
            )

        case let .agentOverflow(_, count):
            AgentOverflowRow(count: count)
        }
    }

    /// Count on the left where reading starts, actions on the right. The brand mark that used to hold
    /// the left edge has moved to the settings window: it was the only thing in the header that was
    /// neither a number nor a button, and the notch itself already carries the identity.
    private var header: some View {
        HStack(spacing: metrics.size(7)) {
            Text(summary)
                .font(metrics.font(10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.dim)

            Spacer()

            HStack(spacing: metrics.size(4)) {
                HeaderButton(symbol: "gearshape", help: "Notchling settings", action: actions.settings)
                HeaderButton(
                    symbol: "arrow.clockwise",
                    help: "Restart the widget, picking up any version installed since it started",
                    action: actions.restart
                )
                HeaderButton(symbol: "power", help: "Stop the widget", action: actions.stop)
            }
        }
        .padding(.horizontal, metrics.size(Self.contentInset))
    }

    private var summary: String {
        let count = layout.sessionCount
        return count == 1 ? "1 session" : "\(count) sessions"
    }
}

/// One icon in the header.
///
/// The hit target is deliberately larger than the glyph and squarer than it: these sit next to each
/// other, one of them ends the widget, and a 10pt icon is a 10pt target unless something says
/// otherwise. The gap between two of them is set by the header, not here.
private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @Environment(\.widgetMetrics) private var metrics
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(metrics.font(10, weight: .semibold))
                .foregroundStyle(Theme.dim)
                .frame(width: metrics.size(16), height: metrics.size(16))
                .background {
                    RoundedRectangle(cornerRadius: metrics.size(4))
                        .fill(isHovering ? Theme.surface : Theme.surface.opacity(0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// An upgrade that has landed on disk but is not what this process is running. Replacing an app's
/// files leaves the running one alone, and every other signal — the package manager, the `opt` path —
/// already reports the new version, so this row is the only place the difference is visible.
private struct UpgradeNoticeRow: View {
    let version: String
    let onRestart: () -> Void

    @Environment(\.widgetMetrics) private var metrics
    @State private var isHovering = false

    var body: some View {
        Button(action: onRestart) {
            HStack(spacing: metrics.size(6)) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(metrics.font(11))
                    .foregroundStyle(Theme.amber)

                Text("Version \(version) installed")
                    .font(metrics.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink)

                Spacer(minLength: metrics.size(4))

                Text("Restart")
                    .font(metrics.font(10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.amber)
            }
            .padding(.vertical, metrics.size(5))
            .padding(.horizontal, metrics.size(7))
            .background {
                RoundedRectangle(cornerRadius: metrics.size(7))
                    .fill(isHovering ? Theme.surface : Theme.surface.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("This widget is still running the previous build. Restart to pick up \(version).")
    }
}
