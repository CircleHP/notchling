//
//  A discrete blocked meter, shared by the plan-limit bars and the per-session context meter.
//
//  Drawn in a single `Canvas` rather than built from a `RoundedRectangle` per segment. The panel holds
//  six of these — two 14-segment usage bars and one 6-segment context meter per session — so the view
//  version created upwards of fifty views plus six `GeometryReader`s every time the panel opened.
//
//  Building the panel is the largest single cost of opening it, and this was the largest part of that.
//

import SwiftUI

struct SegmentedMeter: View {
    /// 0…1. Values outside are clamped.
    let fraction: Double
    let tint: Color
    var segments: Int = 14
    var gap: CGFloat = 2
    var cornerRadius: CGFloat = 1

    private var filled: Int {
        // Round rather than floor so a nearly-full segment is not shown as empty, but never round a
        // non-zero fraction down to nothing, or "1% used" reads as "nothing used".
        let clamped = min(1, max(0, fraction))
        guard clamped > 0 else { return 0 }
        return max(1, Int((Double(segments) * clamped).rounded()))
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let width = max(1, (size.width - gap * CGFloat(segments - 1)) / CGFloat(segments))
            let empty = Theme.hairline
            let lit = filled
            for index in 0 ..< segments {
                let rect = CGRect(
                    x: (width + gap) * CGFloat(index),
                    y: 0,
                    width: width,
                    height: size.height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: cornerRadius),
                    with: .color(index < lit ? tint : empty)
                )
            }
        }
        .allowsHitTesting(false)
    }
}
