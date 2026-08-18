//
//  What the widget shows at rest. This is where it spends almost all of its life, so it is
//  deliberately quiet: the mascot alone when nothing needs you, and a count only when a number would
//  tell you something.
//
//  Sizes here are unscaled on purpose. The `scale` preference belongs to the panel — this strip has to
//  live inside a menu bar, and there is nothing in it that benefits from being bigger.
//

import SwiftUI

struct CompactLeadingView: View {
    let store: SessionStore
    @Environment(\.widgetMetrics) private var metrics

    var body: some View {
        MascotView(state: store.aggregateState, height: metrics.mascotHeight)
    }
}

struct CompactTrailingView: View {
    let store: SessionStore

    /// At most two, most urgent first.
    ///
    /// Purely about glanceability now, not width: the strip is sized by its contents, so a fourth cluster
    /// would simply make it wider rather than overflowing anything. Three is where a row of coloured dots
    /// stops being readable at a glance, which is the only thing the strip is for. The panel — one hover
    /// away — lists every session individually.
    static let maximumBadges = 3

    private var badges: [(state: SessionState, count: Int)] {
        [
            (.needsYou, store.needsYouCount),
            (.error, store.errorCount),
            (.working, store.workingCount),
            (.done, store.doneCount),
        ]
        .filter { $0.count > 0 }
        .prefix(Self.maximumBadges)
        .map { $0 }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(badges, id: \.state) { badge in
                HStack(spacing: 2.5) {
                    Circle()
                        .fill(Theme.color(for: badge.state))
                        .frame(width: 5, height: 5)
                    Text("\(badge.count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: badges.map(\.count))
    }
}
