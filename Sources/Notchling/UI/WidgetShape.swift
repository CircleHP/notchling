//
//  The silhouette: square against the top edge of the screen, concave fillets flaring out into the
//  bezel, convex corners along the bottom. On the built-in display this is the shape of the notch
//  itself, so the widget looks like the hardware grew. On an external display it is the same shape
//  drawn in black, which is why it reads as a notch on a screen that does not have one.
//

import SwiftUI

struct WidgetShape: Shape {
    /// Radius of the two concave fillets at the top, where the shape meets the screen edge.
    var topRadius: CGFloat
    /// Radius of the two convex corners along the bottom.
    var bottomRadius: CGFloat

    /// Animate the corners, so growing from compact to expanded is one continuous movement rather
    /// than a rounded box appearing inside a square one.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let width = rect.width
        let height = rect.height
        let originX = rect.minX
        let originY = rect.minY
        // A fillet cannot be wider than half the shape, and the two radii together cannot exceed the
        // height, or the curves cross over and the path folds inside out.
        let top = min(topRadius, width / 2, height)
        let bottom = min(bottomRadius, (width - top * 2) / 2, height - min(top, height / 2))

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x, y: originY + y)
        }

        path.move(to: point(0, 0))
        // Concave: the control point sits in the corner the curve is bending away from.
        path.addQuadCurve(to: point(top, top), control: point(top, 0))
        path.addLine(to: point(top, height - bottom))
        path.addQuadCurve(to: point(top + bottom, height), control: point(top, height))
        path.addLine(to: point(width - top - bottom, height))
        path.addQuadCurve(to: point(width - top, height - bottom), control: point(width - top, height))
        path.addLine(to: point(width - top, top))
        path.addQuadCurve(to: point(width, 0), control: point(width - top, 0))
        path.closeSubpath()

        return path
    }
}


/// The shape as the widget actually animates it: a `WidgetShape` of a given size, drawn top-centre
/// inside whatever box it is handed.
///
/// This exists so the growth is a **draw-time** change rather than a layout change. Animating the
/// container's frame instead calls `NSHostingView.layout()` on every frame, which re-runs SwiftUI's
/// AttributeGraph over the whole panel — profiled at 17% CPU for a third of a second. Animating four
/// numbers into a `Path` costs a dozen Bézier operations and no layout at all.
struct AnimatedWidgetShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(width, height), .init(topRadius, bottomRadius)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Clamp *first*, then centre the clamped size. Centring the un-clamped width has a distinctive
        // failure mode: an opening spring overshoots past the layout box, `min` pins the drawn width
        // there, and the offset carries on tracking the overshoot and goes negative — so the shape stops
        // growing and starts *sliding*. It shows only on video at frame rate, as the drawn width holding
        // at 828px while the whole widget drifts 7px left and 8px back right.
        let drawnWidth = min(max(width, 0), rect.width)
        let drawnHeight = min(max(height, 0), rect.height)

        // Deliberately not rounded. The width animates continuously, so rounding the offset makes the
        // left edge snap a point at a time while the right edge moves smoothly, which shimmers.
        let box = CGRect(
            x: rect.minX + (rect.width - drawnWidth) / 2,
            y: rect.minY,
            width: drawnWidth,
            height: drawnHeight
        )
        return WidgetShape(topRadius: topRadius, bottomRadius: bottomRadius).path(in: box)
    }
}
