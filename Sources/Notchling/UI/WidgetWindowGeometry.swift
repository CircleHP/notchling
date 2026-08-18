//
//  What size the window should be. `WidgetPresenter` decides *when* it may change.
//
//  The window is sized to what it actually draws, which is not a nicety: a window is opaque to mouse
//  events across its whole rect regardless of what it painted there, so slack is a dead zone over
//  whatever is underneath.
//

import AppKit

/// What the content measured, and where it needs the window put.
struct WidgetContentGeometry: Equatable {
    let size: CGSize
    /// How far right of the screen centre the window's centre must sit for the gap in the compact strip
    /// to land on the cutout. Zero when the strip is symmetric, or when there is no cutout.
    let gapOffset: CGFloat

    init(size: CGSize, gapOffset: CGFloat = 0) {
        self.size = size
        self.gapOffset = gapOffset
    }
}

struct WidgetWindowGeometry {
    /// Sizes the content settled on, so a transition can size the window before anything moves rather
    /// than chasing it.
    private var measured: [WidgetPresentation: WidgetContentGeometry] = [:]

    /// `hidden` and `compact` lay out identically — hiding is opacity and an offset, not a size change —
    /// so they share one measurement.
    ///
    /// Keying on the presentation directly does not work. The first measurement arrives while the state
    /// is still `hidden`, because SwiftUI lays the hosting view out before the animation to `compact`
    /// runs; filed under `hidden` it never reached `compact`, and since the size then never *changed*
    /// again there was no second event to correct it.
    static func sizeKey(_ presentation: WidgetPresentation) -> WidgetPresentation {
        presentation == .expanded ? .expanded : .compact
    }

    /// Records a measurement. Returns true when it is new information worth acting on.
    mutating func record(
        _ geometry: WidgetContentGeometry,
        for presentation: WidgetPresentation
    ) -> Bool {
        guard geometry.size.width > 1, geometry.size.height > 1 else { return false }
        let key = Self.sizeKey(presentation)
        guard measured[key] != geometry else { return false }
        measured[key] = geometry
        return true
    }

    func has(_ presentation: WidgetPresentation) -> Bool {
        measured[Self.sizeKey(presentation)] != nil
    }

    /// Deliberately *not* called when the screen's metrics change: a stale-but-tight size is corrected by
    /// the next real measurement, where an empty cache falls back to the generous window and may never be
    /// corrected, because a size that does not change reports nothing.
    mutating func forget() {
        measured = [:]
    }

    func frame(
        for presentation: WidgetPresentation,
        metrics: WidgetMetrics,
        screenFrame: CGRect
    ) -> NSRect {
        let recorded = measured[Self.sizeKey(presentation)]
        let content = recorded?.size ?? fallback(
            for: presentation,
            metrics: metrics,
            screenFrame: screenFrame
        )

        // Never larger than the display. A measured size is whatever the content asked for, and with
        // enough sessions the panel asks for more than the screen has — at which point the window extends
        // past the edge, those rows are unreachable rather than merely cut off, and in a stacked display
        // arrangement it can bleed onto the neighbour. The row cap in `ExpandedView` is what stops it
        // getting here; this is the backstop.
        let size = CGSize(
            width: min(content.width, screenFrame.width),
            height: min(content.height, screenFrame.height)
        )

        // Whole points, so the shape does not land on a half point and soften its own edges. The width is
        // rounded up to an *even* number as well: the frame is centred by subtracting half the width, so
        // an odd width leaves the window half a point off centre — 1 device pixel of asymmetry on a 2x
        // display, in the one dimension the widget is most carefully aligned in.
        let width = min((size.width / 2).rounded(.up) * 2, screenFrame.width)
        let height = size.height.rounded(.up)
        // The compact strip grows on its badge side only, so it is positioned by its *gap* rather than
        // centred. That is what keeps the mascot still: solve for the window origin and the trailing
        // width cancels out, so the mascot's position depends only on its own width and the cutout's.
        // The expanded panel is centred as usual.
        let offset = presentation == .expanded ? 0 : (recorded?.gapOffset ?? 0)
        return NSRect(
            x: (screenFrame.midX + offset - width / 2).rounded(),
            y: (screenFrame.maxY - height).rounded(),
            width: width,
            height: height
        )
    }

    /// Never measured in this state yet. Be generous so the content has room to lay out naturally —
    /// `.fixedSize()` reports the right size even when the window is too small, so this costs at most one
    /// frame of clipping, once per state. The width is known without measuring, because `ExpandedView`
    /// is a fixed width plus known padding; only the height has to be guessed.
    private func fallback(
        for presentation: WidgetPresentation,
        metrics: WidgetMetrics,
        screenFrame: CGRect
    ) -> CGSize {
        let width = min(screenFrame.width, metrics.size(ExpandedView.panelWidth + 60))
        return switch presentation {
        case .expanded:
            CGSize(width: width, height: min(screenFrame.height * 0.92, metrics.size(760)))
        case .compact, .hidden:
            CGSize(width: width, height: metrics.anchorSize.height + metrics.size(28))
        }
    }
}
