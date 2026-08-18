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

    /// Unscaled. `WidgetPresenter` needs this before any view exists, to size the window.
    static let panelWidth: CGFloat = 380

    let store: SessionStore
    let onFocus: (Session) -> Void
    let onQuit: () -> Void

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

    @Environment(\.widgetMetrics) private var metrics

    init(store: SessionStore, onFocus: @escaping (Session) -> Void, onQuit: @escaping () -> Void) {
        self.store = store
        self.onFocus = onFocus
        self.onQuit = onQuit
        _layout = State(initialValue: PanelLayout(sessions: store.sessions))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.size(8)) {
            header

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
            SessionRow(session: store.session(id: captured.sessionID) ?? captured, onFocus: onFocus)

        case let .agent(sessionID, captured):
            AgentRow(
                agent: store.session(id: sessionID)?.agents[captured.agentID] ?? captured,
                isLast: layout.isLastInBlock(index),
                onFocus: {
                    guard let session = store.session(id: sessionID) else { return }
                    onFocus(session)
                }
            )

        case let .agentOverflow(_, count):
            AgentOverflowRow(count: count)
        }
    }

    private var header: some View {
        HStack(spacing: metrics.size(7)) {
            BrandMarkView(height: metrics.snapped(12))

            Spacer()

            Text(summary)
                .font(metrics.font(10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.dim)

            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(metrics.font(10, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            .help("Quit Notchling")
        }
        .padding(.horizontal, metrics.size(Self.contentInset))
    }

    private var summary: String {
        let count = layout.sessionCount
        return count == 1 ? "1 session" : "\(count) sessions"
    }
}
