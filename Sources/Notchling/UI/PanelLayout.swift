//
//  What the panel shows, and what it says about the rest.
//
//  Measured before any of this existed: fourteen live sessions produced a panel 1184pt tall on a 1440pt
//  display, and nothing capped it — beyond about seventeen the window ran off the bottom of the screen and
//  those rows could not be reached at all. A list that tall has also stopped being glanceable, which is the
//  only thing it is for.
//
//  A row is either a session or one of its agents, so the cap has to span both.
//

import Foundation

/// One line in the panel.
enum PanelRow: Identifiable, Equatable {
    case session(Session)
    case agent(sessionID: String, agent: SubagentActivity)
    /// The agents of one session that did not fit.
    case agentOverflow(sessionID: String, count: Int)

    var id: String {
        switch self {
        case let .session(session): "s:\(session.sessionID)"
        case let .agent(sessionID, agent): "a:\(sessionID):\(agent.agentID)"
        case let .agentOverflow(sessionID, _): "o:\(sessionID)"
        }
    }

    /// The session this row belongs to — itself, or the one that spawned it.
    var sessionID: String {
        switch self {
        case let .session(session): session.sessionID
        case let .agent(sessionID, _): sessionID
        case let .agentOverflow(sessionID, _): sessionID
        }
    }

    var isSession: Bool {
        if case .session = self { return true }
        return false
    }

    var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }
}

struct PanelLayout {
    static let maximumRows = 10

    /// Per session, so one fan-out cannot fill the panel by itself. The aggregate — how many agents and
    /// how many have finished — is on the session's own line, so a low cap here does not cost the
    /// "4 of 5 done" reading that makes the tree worth having.
    static let maximumAgentRows = 4

    let rows: [PanelRow]
    let hiddenSessions: [Session]

    init(
        sessions: [Session],
        limit: Int = Self.maximumRows,
        agentLimit: Int = Self.maximumAgentRows
    ) {
        let shown = Array(sessions.prefix(limit))
        hiddenSessions = Array(sessions.dropFirst(limit))

        // Sessions claim their rows first, and only what is left over is spent on agents. Emitting each
        // session's agents as they are walked would let a fan-out on the most urgent session push a second
        // session off the list entirely — and the sessions are what you navigate to, while the agents are
        // detail about one of them.
        var remaining = limit - shown.count
        var built: [PanelRow] = []
        for session in shown {
            built.append(.session(session))
            let agentRows = Self.agentRows(for: session, budget: remaining, agentLimit: agentLimit)
            built.append(contentsOf: agentRows)
            remaining -= agentRows.count
        }
        rows = built
    }

    /// Agents are worth rows only while their session is still doing something about them. A finished or
    /// resting session's internal structure does not inform what to do next, which is the only question
    /// the panel exists to answer.
    private static func showsAgents(of session: Session) -> Bool {
        session.state == .working || session.state == .needsYou
    }

    private static func agentRows(
        for session: Session,
        budget: Int,
        agentLimit: Int
    ) -> [PanelRow] {
        guard budget > 0, showsAgents(of: session) else { return [] }
        let agents = session.sortedAgents
        guard !agents.isEmpty else { return [] }

        let slots = min(budget, agentLimit)
        // An overflow line costs a row of its own, taken out of this session's allowance rather than
        // borrowed from the next session's.
        let visible = agents.count > slots ? slots - 1 : agents.count

        var rows: [PanelRow] = agents.prefix(visible).map {
            .agent(sessionID: session.sessionID, agent: $0)
        }
        if agents.count > visible {
            rows.append(.agentOverflow(sessionID: session.sessionID, count: agents.count - visible))
        }
        return rows
    }

    /// Whether the row at `index` closes its session's block, which is what decides the tree glyph.
    func isLastInBlock(_ index: Int) -> Bool {
        guard rows.indices.contains(index) else { return false }
        let next = index + 1
        guard rows.indices.contains(next) else { return true }
        return rows[next].isSession || rows[next].sessionID != rows[index].sessionID
    }

    /// How many sessions this layout accounts for, drawn or not.
    ///
    /// The header counts these rather than the live store: the rows are frozen while the panel is open, and
    /// a header that kept counting live would contradict what is on screen the moment a session ends
    /// mid-hover — which is exactly when someone is reading it.
    var sessionCount: Int {
        rows.reduce(0) { $0 + ($1.isSession ? 1 : 0) } + hiddenSessions.count
    }

    /// `3 more idle` and `3 more` are different promises: one says nothing is being hidden that you would
    /// act on, the other admits that something might be.
    var summary: String? {
        guard !hiddenSessions.isEmpty else { return nil }
        let allIdle = hiddenSessions.allSatisfy { $0.state == .idle }
        return "\(hiddenSessions.count) more\(allIdle ? " idle" : "")"
    }
}
