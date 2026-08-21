//
//  What the panel draws, where that is a matter of taste rather than of what is happening.
//
//  Plain booleans, unlike `UpdatePreference` next door. That one is tri-state because an unanswered
//  question there means "has not touched the network yet"; nothing here has anything to consent to,
//  so an absent key is simply the default and the only states are on and off.
//
//  Read live rather than once at launch — unlike `Scale` and `DisplayMode`, which need a relaunch —
//  because the switch is in a window the panel is visible from, and a preference that needs the widget
//  restarted to take effect is one people assume is broken.
//

import Foundation

enum PanelPreference {
    static let planUsageKey = "showPlanUsage"

    /// The 5-hour and 7-day plan bars along the bottom of the panel.
    ///
    /// On unless it has been turned off. Wiring the status line is already a question `notchling-hooks
    /// setup` asks, so a machine with usage to show has asked for it once already; this is for changing
    /// your mind afterwards, which otherwise means editing `~/.claude/settings.json` and restarting
    /// every running session.
    ///
    /// Per-session context is deliberately not covered by this. It comes from the same status line, but
    /// it sits inside a row that is being read anyway rather than occupying a block of its own.
    static var showsPlanUsage: Bool {
        get { UserDefaults.standard.object(forKey: planUsageKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: planUsageKey) }
    }
}
