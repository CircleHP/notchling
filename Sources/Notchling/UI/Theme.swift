//
//  Every colour in the widget. Nothing outside this file constructs one.
//
//  The widget draws on its own opaque black chrome, not on the system appearance, so the palette is a
//  handful of hues plus a neutral ramp of white-on-black alphas. `ThemeTests` fails the build if a colour
//  literal appears anywhere else — inlined values drift, and eight of these had.
//

import SwiftUI

enum Theme {
    // MARK: - Hues

    /// The identity colour. Named for what it looks like rather than where it came from.
    static let clay = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let amber = Color(red: 245 / 255, green: 180 / 255, blue: 60 / 255)
    static let green = Color(red: 110 / 255, green: 200 / 255, blue: 130 / 255)
    static let red = Color(red: 232 / 255, green: 95 / 255, blue: 85 / 255)

    // MARK: - Neutrals

    /// The widget's body. Opaque, because on a notched display it has to match a hole in the screen.
    static let chrome = Color.black

    /// Text that is the point of the row: session names, counts.
    static let ink = Color.white.opacity(0.95)
    /// Supporting text: what a session is doing, tags.
    static let inkSecondary = Color.white.opacity(0.55)
    /// Labels and units — present, not competing. Also the resting state's dot.
    static let dim = Color.white.opacity(0.38)

    /// Chips, and the highlight under a hovered row.
    static let surface = Color.white.opacity(0.10)
    /// Dividers, and the unfilled part of a meter.
    static let hairline = Color.white.opacity(0.13)

    // MARK: - Derived

    /// The ring a dot draws around itself when its state wants attention.
    static let attentionRingOpacity: Double = 0.4
    /// Applied to a whole row's worth of text when the numbers behind it have gone stale.
    static let staleOpacity: Double = 0.55

    // MARK: - Session colour

    /// A colour a user set with `/color`, mapped from the terminal palette Claude Code offers. Unknown
    /// names return nil rather than a guess: no marker is better than the wrong one, and the palette
    /// can grow without this having to know.
    static func sessionColor(named name: String?) -> Color? {
        switch name?.lowercased() {
        case "red": red
        case "green": green
        case "yellow", "amber": amber
        case "blue": Color(red: 100 / 255, green: 160 / 255, blue: 235 / 255)
        case "magenta", "pink": Color(red: 210 / 255, green: 120 / 255, blue: 200 / 255)
        case "cyan": Color(red: 100 / 255, green: 200 / 255, blue: 210 / 255)
        case "white": ink
        case "gray", "grey": dim
        // A name we do not recognise still means the user set one, and showing nothing is
        // indistinguishable from never having set it. Neutral rather than absent.
        case .some(let other) where !other.isEmpty: inkSecondary
        default: nil
        }
    }

    // MARK: - State

    static func color(for state: SessionState) -> Color {
        switch state {
        // Red, not amber: the mascot frowns for both attention states, and a dot that disagreed with the
        // face it sits next to just looks like a bug. The row still spells out which one it is.
        case .needsYou: red
        case .error: red
        case .working: clay
        case .done: green
        case .idle: dim
        }
    }

    /// Colour is the second channel here, not the only one — every state also has its own face, which is
    /// what survives being seen peripherally or by someone who cannot separate clay from red.
    ///
    /// Deliberately delegates to `color(for:)` rather than keeping a second table. The two drifted once,
    /// and the notch showed clay for needs-you while the panel showed amber. `idle` is the single
    /// exception: the dot dims to grey, while the critter stays clay and `MascotView` lowers its opacity.
    static func mascotColor(for state: SessionState) -> Color {
        state == .idle ? clay : color(for: state)
    }

    static func label(for state: SessionState) -> String {
        switch state {
        case .needsYou: "needs you"
        case .working: "working"
        case .done: "done"
        case .error: "failed"
        case .idle: "idle"
        }
    }

    /// How full is too full, shared by the plan-limit bars and the per-session context meter.
    ///
    /// `resting` is the one thing that legitimately differs: a plan limit is a headline and sits in clay,
    /// while a context meter is a detail that would compete with the state dot beside it.
    static func fillTint(usedFraction: Double, resting: Color) -> Color {
        switch usedFraction {
        case 0.90...: red
        case 0.75...: amber
        default: resting
        }
    }
}

extension TimeInterval {
    /// `4s`, `1m12s`, `2h05m`.
    var elapsedLabel: String {
        let total = Int(max(0, self))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m\(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h\(String(format: "%02d", (total % 3600) / 60))m"
    }
}
