//
//  The bridge between the presenter and SwiftUI: observable state, and the root view that reads it.
//

import SwiftUI

/// Observable so the content re-renders on a presentation change without the panel being rebuilt.
/// Rebuilding the hosting view restarts the mascot's frame driver, which is visible.
@MainActor
@Observable
final class WidgetViewState {
    var presentation: WidgetPresentation = .hidden
    /// Set from the moment a transition starts until it finishes. While it is set the widget keeps the
    /// *expanded* layout box and animates only its mask — see `AnimatedWidgetShape`.
    var isTransitioning = false
    var metrics: WidgetMetrics

    init(metrics: WidgetMetrics) {
        self.metrics = metrics
    }
}

struct WidgetRoot: View {
    let store: SessionStore
    let state: WidgetViewState
    let onHover: (Bool) -> Void
    let onContentGeometry: (WidgetPresentation, WidgetContentGeometry) -> Void
    let actions: WidgetActions

    var body: some View {
        WidgetView(
            store: store,
            metrics: state.metrics,
            presentation: state.presentation,
            isTransitioning: state.isTransitioning,
            onHover: onHover,
            onContentGeometry: onContentGeometry,
            actions: actions
        )
    }
}
