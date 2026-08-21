//
//  Whether the widget may look for new releases, and when it last did.
//
//  Tri-state on purpose. "Not asked" is not "no": it is the state in which the panel puts the question
//  and nothing touches the network. Only an answer — either answer — retires it. That is what keeps
//  the claim in README and NOTICE honest, and it is why this is not a `Bool` with a default.
//
//  Kept in `UserDefaults`, domain `local.notchling`, beside `externalScale` and `displayMode`. Read
//  live rather than once at launch, unlike those two, because the toggle in the settings window has to
//  take effect without a restart.
//

import Foundation

enum UpdatePreference {
    static let defaultsKey = "checkForUpdates"
    /// `yyyy-MM-dd` of the last check, so the daily rule survives a restart.
    static let lastCheckedKey = "lastUpdateCheckDay"
    static let hourKey = "updateCheckHour"

    /// 11am, local time. An hour the machine is normally awake for, so the check usually happens when
    /// it says it does rather than whenever the lid next opens. Only a default — the settings window
    /// owns the real value, because whose machine is awake when is not something this can know.
    static let defaultHour = 11

    /// Clamped on the way out rather than trusted: this is a plain `defaults` key, and an hour of 47
    /// would mean a check that is never due and a feature that silently does nothing.
    static var hour: Int {
        get {
            guard let stored = UserDefaults.standard.object(forKey: hourKey) as? Int else {
                return defaultHour
            }
            return min(23, max(0, stored))
        }
        set { UserDefaults.standard.set(min(23, max(0, newValue)), forKey: hourKey) }
    }

    /// `9am`, `11am`, `3pm` — for the settings window and for the sentence explaining what it does.
    static func label(forHour hour: Int) -> String {
        switch hour {
        case 0: "12am"
        case 1 ... 11: "\(hour)am"
        case 12: "12pm"
        default: "\(hour - 12)pm"
        }
    }

    enum Choice: Equatable {
        /// Never asked. No network, and the panel is showing the question.
        case unset
        case on
        case off
    }

    static var current: Choice {
        guard let value = UserDefaults.standard.object(forKey: defaultsKey) as? Bool else {
            return .unset
        }
        return value ? .on : .off
    }

    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }

    // MARK: - The daily rule

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func day(of date: Date) -> String { formatter().string(from: date) }

    /// Whether a check is due: enabled, past this morning's hour, and not already done today.
    ///
    /// Wall-clock and calendar-based rather than an interval, for the same reason the version check is
    /// — a machine that slept through 11:00 should check on the sweep after it wakes, not count only
    /// the time it was awake.
    static func isDue(
        now: Date,
        lastCheckedDay: String?,
        choice: Choice,
        hour: Int = UpdatePreference.hour,
        calendar: Calendar = .current
    ) -> Bool {
        guard choice == .on else { return false }
        guard lastCheckedDay != day(of: now) else { return false }
        if calendar.component(.hour, from: now) >= hour { return true }

        // The hour has not come round yet today. Normally that means wait — but a machine that is
        // never awake at the chosen hour would then never check at all, which the hour picker made
        // easy to arrange by accident. Never checked, or not for a whole day, overrides it.
        guard let lastCheckedDay else { return true }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
        return lastCheckedDay < day(of: yesterday)
    }

    static var lastCheckedDay: String? {
        get { UserDefaults.standard.string(forKey: lastCheckedKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastCheckedKey) }
    }
}
