//
//  How long transitions take and what curve they follow.
//

import SwiftUI

enum WidgetTiming {
    /// `NOTCHLING_ANIM=6` slows every transition down 6x. No screenshot tool here samples faster than
    /// about a quarter of a second, so this is the only way to inspect a transition mid-flight.
    private static let factor: Double = {
        guard let raw = ProcessInfo.processInfo.environment["NOTCHLING_ANIM"],
              let value = Double(raw), value > 0, value <= 60
        else { return 1 }
        return value
    }()

    static func seconds(_ base: Double) -> Double { base * factor }
    static func milliseconds(_ base: Int) -> Int { Int(Double(base) * factor) }

    static func duration(to presentation: WidgetPresentation, hasPanel: Bool) -> Double {
        guard hasPanel else { return 0.28 }
        return presentation == .expanded ? 0.34 : 0.26
    }

    /// Opening springs, closing does not. A little overshoot on the way out reads as the panel dropping
    /// from the notch; the same overshoot on the way back in has nothing to drop into and reads as a
    /// wobble, because the shape shrinks past the compact strip and springs back out to it.
    static func curve(to presentation: WidgetPresentation, hasPanel: Bool) -> Animation {
        let seconds = seconds(duration(to: presentation, hasPanel: hasPanel))
        guard hasPanel else {
            // First appearance: no previous size to travel from, so a spring has nothing to say.
            return .smooth(duration: seconds)
        }
        return presentation == .expanded
            ? .bouncy(duration: seconds, extraBounce: 0.05)
            : .smooth(duration: seconds)
    }
}
