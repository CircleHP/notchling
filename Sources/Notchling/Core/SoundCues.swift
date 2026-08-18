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
    private var lastPlayed: [String: SessionState] = [:]

    /// Turns already announced as stalled, keyed session+turn.
    private var stallPlayed: Set<String> = []

    /// Injectable only so the deduplication above can be asserted on; the dedupe is the logic here,
    /// and it has no other observable output.
    private let play: (String) -> Void

    init(play: @escaping (String) -> Void = { NSSound(named: $0)?.play() }) {
        self.play = play
    }

    func play(for session: Session, newState: SessionState) {
        guard newState.isNotifiable else { return }
        guard lastPlayed[session.sessionID] != newState else { return }
        lastPlayed[session.sessionID] = newState

        switch newState {
        case .needsYou: play("Submarine")
        case .done: play("Glass")
        case .error: play("Basso")
        case .working, .idle: break
        }
    }

    /// Keyed by turn rather than by session: one long turn should say so once, and the *next* turn
    /// stalling is genuinely new information.
    func playStalled(for session: Session) {
        let key = "\(session.sessionID)|\(session.currentPromptID ?? "-")"
        guard !stallPlayed.contains(key) else { return }
        stallPlayed.insert(key)

        if stallPlayed.count > 500 { stallPlayed.removeAll() }

        play("Tink")
    }

    /// Called when a session leaves a notifiable state, so the next entry sounds again.
    func clearDedupe(for sessionID: String) {
        lastPlayed.removeValue(forKey: sessionID)
    }
}
