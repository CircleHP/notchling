//
//  A distinct sound per state edge. Paired with the notch dropping open (see `WidgetController.peek`),
//  this is the whole alerting story: the widget is already on screen, so a banner in Notification
//  Center would say the same thing twice and then need dismissing.
//  `NSSound` needs no authorization and no bundle entitlement, which is what makes this cheap.
//

import AppKit

@MainActor
final class SoundCues {
    /// The last state each session was announced in, so re-entering a state without leaving it first
    /// — a second permission prompt in the same turn, say — stays quiet.
    private var lastPlayed: [SessionKey: SessionState] = [:]

    /// Turns already announced as stalled, keyed session+turn.
    private var stallPlayed: Set<String> = []

    /// Injectable only so the deduplication above can be asserted on; the dedupe is the logic here,
    /// and it has no other observable output.
    private let play: (String) -> Void
    /// Whether an event's sound is switched on. Consulted *after* the dedupe is updated, so an event
    /// that arrives muted is still remembered: turning the sound on mid-prompt must not announce a
    /// prompt that was already up.
    private let isAudible: (AlertEvent) -> Bool

    init(
        isAudible: @escaping (AlertEvent) -> Bool = { AlertPreference.allows($0, on: .sound) },
        play: @escaping (String) -> Void = { NSSound(named: $0)?.play() }
    ) {
        self.isAudible = isAudible
        self.play = play
    }

    func play(for session: Session, newState: SessionState) {
        guard let event = AlertEvent(state: newState) else { return }
        guard lastPlayed[session.key] != newState else { return }
        lastPlayed[session.key] = newState

        if isAudible(event) { play(Self.sound(for: event)) }
    }

    /// Keyed by turn rather than by session: one long turn should say so once, and the *next* turn
    /// stalling is genuinely new information.
    func playStalled(for session: Session) {
        let key = "\(session.key.storageKey)|\(session.currentPromptID ?? "-")"
        guard !stallPlayed.contains(key) else { return }
        stallPlayed.insert(key)

        if stallPlayed.count > 500 { stallPlayed.removeAll() }

        if isAudible(.stalled) { play(Self.sound(for: .stalled)) }
    }

    private static func sound(for event: AlertEvent) -> String {
        switch event {
        case .needsYou: "Submarine"
        case .error: "Basso"
        case .stalled: "Tink"
        case .done: "Glass"
        }
    }

    /// Called when a session leaves a notifiable state, so the next entry sounds again.
    func clearDedupe(for key: SessionKey) {
        lastPlayed.removeValue(forKey: key)
    }
}
