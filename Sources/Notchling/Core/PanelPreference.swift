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
    /// Claude's key keeps its original name, so nobody who turned the bars off gets them back.
    static let planUsageKey = "showPlanUsage"

    /// The 5-hour and 7-day plan lines along the bottom of the panel, per agent.
    ///
    /// One switch each, because they are separate accounts on separate plans: someone who pays for one
    /// and not the other has no reason to give up a line of the panel to the one they do not.
    ///
    /// On unless turned off. Wiring is already a question `notchling-hooks setup` asks, so a machine
    /// with usage to show has asked for it once already; this is for changing your mind afterwards,
    /// which otherwise means editing a config file and restarting every running session.
    ///
    /// Per-session context is deliberately not covered by this. It comes from the same place, but it
    /// sits inside a row that is being read anyway rather than occupying a block of its own.
    static func showsPlanUsage(for provider: Provider) -> Bool {
        UserDefaults.standard.object(forKey: key(for: provider)) as? Bool ?? true
    }

    static func setShowsPlanUsage(_ shown: Bool, for provider: Provider) {
        UserDefaults.standard.set(shown, forKey: key(for: provider))
    }

    static func key(for provider: Provider) -> String {
        provider == .claude ? planUsageKey : "showPlanUsage.\(provider.rawValue)"
    }
}
