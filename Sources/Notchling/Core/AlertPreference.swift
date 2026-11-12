//
//  Which session events open the panel on their own, and which play a sound.
//
//  Plain booleans, like `PanelPreference`: an absent key is the default, and the default is on, so an
//  upgrade changes nobody's alerts. Read live, at the moment an event fires, so a switch flipped in
//  the settings window applies to the very next one.
//
//  Hovering the widget is not an alert and is never governed by this. Turning everything off leaves a
//  widget that only opens when you point at it.
//

import Foundation

/// The events that alert. One per row of the settings grid.
enum AlertEvent: String, CaseIterable, Sendable {
    case needsYou
    case error
    case stalled
    case done

    /// The event a state change is, if it is one that alerts. Stalling is not a state — it arrives
    /// separately, from `SessionStore.onStalled`.
    init?(state: SessionState) {
        switch state {
        case .needsYou: self = .needsYou
        case .error: self = .error
        case .done: self = .done
        case .working, .idle: return nil
        }
    }

    var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .error: "Error"
        case .stalled: "Stalled"
        case .done: "Done"
        }
    }
}

/// The two halves of an alert, switched independently.
enum AlertChannel: String, CaseIterable, Sendable {
    case popUp
    case sound
}

enum AlertPreference {
    static let enabledKey = "alerts.enabled"

    static func key(for event: AlertEvent, on channel: AlertChannel) -> String {
        "alerts.\(channel.rawValue).\(event.rawValue)"
    }

    /// The master switch. Off silences every event on both channels, whatever the grid says — the grid
    /// keeps its answers, so turning this back on restores them rather than resetting them.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    /// What the grid says for one cell, ignoring the master switch. For drawing the grid.
    static func isChecked(
        _ event: AlertEvent,
        on channel: AlertChannel,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: key(for: event, on: channel)) as? Bool ?? true
    }

    static func setChecked(
        _ checked: Bool,
        _ event: AlertEvent,
        on channel: AlertChannel,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(checked, forKey: key(for: event, on: channel))
    }

    /// Whether this event should alert on this channel right now. For acting on an event.
    static func allows(
        _ event: AlertEvent,
        on channel: AlertChannel,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        isEnabled(in: defaults) && isChecked(event, on: channel, in: defaults)
    }
}
