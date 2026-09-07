import Foundation
import Testing

@testable import Notchling

/// A session id is unique within one agent and means nothing across two. Everything below is a place
/// that keys by session, and would cross-contaminate if the key were the bare id — which is the whole
/// reason `SessionKey` exists.
@Suite("Session identity across providers")
@MainActor
struct SessionIdentityTests {
    private let sameID = "5ad957c8"

    @Test("the same id under two agents is two keys")
    func keysDiffer() {
        let claude = SessionKey(provider: .claude, id: sameID)
        let codex = SessionKey(provider: .codex, id: sameID)

        #expect(claude != codex)
        #expect(claude.storageKey != codex.storageKey)
    }

    @Test("a spool event with no provider is a Claude session")
    func legacyEventIsClaude() {
        let event = hookEvent("SessionStart", session: sameID)
        #expect(event.sessionKey == SessionKey(provider: .claude, id: sameID))
    }

    /// The store looks a session up to answer a click and to keep a frozen row live. Answering the wrong
    /// agent's session there is a row that names another terminal.
    @Test("the store will not answer one agent's lookup with another's session")
    func storeLookupDiscriminates() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit", session: sameID))

        #expect(store.session(key: SessionKey(provider: .claude, id: sameID)) != nil)
        #expect(store.session(key: SessionKey(provider: .codex, id: sameID)) == nil)
    }

    /// The payoff, end to end through the real decode path: two agents reporting the same session id
    /// are two sessions, each carrying its own agent.
    @Test("the same id under two agents is two sessions in the store")
    func storeHoldsBothAgents() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit", session: sameID))
        store.apply(codexEvent("UserPromptSubmit", session: sameID))

        #expect(store.sessions.count == 2)
        #expect(store.session(key: SessionKey(provider: .claude, id: sameID))?.provider == .claude)
        #expect(store.session(key: SessionKey(provider: .codex, id: sameID))?.provider == .codex)
    }

    /// Two rows, not one. `PanelRow.id` is SwiftUI's identity for the list, so a shared id would collapse
    /// two sessions into one row and leave the other undrawable.
    @Test("two agents sharing an id are two rows")
    func panelRowsDiffer() {
        var claude = Session(sessionID: sameID, provider: .claude)
        claude.state = .working
        var codex = Session(sessionID: sameID, provider: .codex)
        codex.state = .working

        let layout = PanelLayout(sessions: [claude, codex])
        #expect(layout.rows.count == 2)
        #expect(Set(layout.rows.map(\.id)).count == 2)
    }

    /// The plan-usage bars are one account's on one agent, so they have to say so the moment anything
    /// else is on screen — and stay unlabelled when there is nothing to distinguish them from.
    @Test("the panel knows when it is showing more than one agent")
    func panelKnowsWhenAgentsAreMixed() {
        var claude = Session(sessionID: "a", provider: .claude)
        claude.state = .working
        var codex = Session(sessionID: "b", provider: .codex)
        codex.state = .working

        #expect(PanelLayout(sessions: [claude]).hasMultipleProviders == false)
        #expect(PanelLayout(sessions: [claude, claude]).hasMultipleProviders == false)
        #expect(PanelLayout(sessions: [claude, codex]).hasMultipleProviders)
    }

    /// Counted over every session rather than the drawn ones, so a caption does not appear and vanish
    /// as rows cross the cap.
    @Test("a second agent below the row cap still counts")
    func hiddenSessionsStillCount() {
        let claude = (0 ..< 10).map { Session(sessionID: "c\($0)", provider: .claude) }
        let codex = [Session(sessionID: "x", provider: .codex)]

        let layout = PanelLayout(sessions: claude + codex, limit: 4)
        #expect(!layout.hiddenSessions.isEmpty)
        #expect(layout.hasMultipleProviders)
    }

    @Test("each agent is named in its own words")
    func agentsAreNamed() {
        #expect(Provider.claude.displayName == "Claude Code")
        #expect(Provider.codex.displayName == "Codex")
    }

    /// The mascot and the strip badges read these, and someone running both agents wants to know that
    /// *something* is blocked rather than which agent it was.
    @Test("counts and the aggregate state span both agents")
    func aggregatesSpanProviders() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit", session: "cc1"))
        store.apply(codexEvent("UserPromptSubmit", session: "cx1"))
        #expect(store.workingCount == 2)
        #expect(store.aggregateState == .working)

        store.apply(codexEvent("Notification", session: "cx1", [
            "notificationType": "permission_prompt",
        ]))
        #expect(store.needsYouCount == 1)
        #expect(store.workingCount == 1)
        #expect(store.aggregateState == .needsYou, "whoever is blocked, someone is")
    }

    /// The cue dedupe is what stops a second permission prompt in one turn sounding twice. Keyed by the
    /// bare id, one agent entering `needsYou` would silence the other's.
    @Test("one agent's cue does not silence the other's")
    func cuesDoNotDedupeAcrossProviders() {
        var played: [String] = []
        let cues = SoundCues { played.append($0) }

        cues.play(for: Session(sessionID: sameID, provider: .claude), newState: .needsYou)
        cues.play(for: Session(sessionID: sameID, provider: .codex), newState: .needsYou)

        #expect(played == ["Submarine", "Submarine"])
    }
}
