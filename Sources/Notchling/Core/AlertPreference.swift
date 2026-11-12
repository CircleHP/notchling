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

import AppKit

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

    /// What this event plays until another sound is chosen for it.
    var defaultSound: String {
        switch self {
        case .needsYou: "Submarine"
        case .error: "Basso"
        case .stalled: "Tink"
        case .done: "Glass"
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

    static func soundKey(for event: AlertEvent) -> String {
        "alerts.soundName.\(event.rawValue)"
    }

    /// The sound this event plays, loaded once. A choice that no longer loads — a file since removed
    /// from `~/Library/Sounds` — falls back to the default rather than going silent.
    static func sound(
        for event: AlertEvent,
        in defaults: UserDefaults = .standard,
        load: (String) -> NSSound? = { NSSound(named: $0) }
    ) -> NSSound? {
        if let chosen = defaults.string(forKey: soundKey(for: event)), let sound = load(chosen) {
            return sound
        }
        return load(event.defaultSound)
    }

    /// The name of the sound this event plays, by the same fallback as `sound(for:)`. For showing the
    /// choice, so the settings never name a sound other than the one an alert plays.
    static func soundName(
        for event: AlertEvent,
        in defaults: UserDefaults = .standard,
        isAvailable: (String) -> Bool = { NSSound(named: $0) != nil }
    ) -> String {
        guard let chosen = defaults.string(forKey: soundKey(for: event)), isAvailable(chosen) else {
            return event.defaultSound
        }
        return chosen
    }

    static func setSound(_ name: String, for event: AlertEvent, in defaults: UserDefaults = .standard) {
        defaults.set(name, forKey: soundKey(for: event))
    }
}

/// The sounds `NSSound(named:)` can find: the system's, and any the user or an admin installed.
enum SoundLibrary {
    static let directories: [URL] = [
        URL(fileURLWithPath: "/System/Library/Sounds"),
        URL(fileURLWithPath: "/Library/Sounds"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds"),
    ]

    private static let extensions: Set<String> = ["aif", "aiff", "caf", "wav", "m4a", "mp3"]

    /// Names without extensions, which is what `NSSound(named:)` takes. A name in more than one
    /// directory is listed once — it resolves to one file either way.
    static func names(in directories: [URL] = directories) -> [String] {
        let files = directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
        }
        let names = files
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
        return Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The names that actually load. A file in one of the directories that `NSSound` cannot decode
    /// would otherwise be offered, saved, and then silently replaced by the default on every alert.
    static func playableNames(
        in directories: [URL] = directories,
        isAvailable: (String) -> Bool = { NSSound(named: $0) != nil }
    ) -> [String] {
        names(in: directories).filter(isAvailable)
    }
}
