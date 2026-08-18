//
//  One subagent of a session, from the moment it is first seen until shortly after it finishes.
//
//  Deliberately not a `Session`. A subagent has no pid, no cwd of its own, no terminal and no registry
//  entry, and it cannot be navigated to independently — clicking it can only ever focus the terminal its
//  session owns. Modelling it as a `Session` would mean a handful of always-nil fields plus teaching the
//  notifier, the strip badges and the focus logic to skip it everywhere.
//
//  Every hook fired inside a subagent arrives with the *parent's* `session_id` and an `agent_id`, so
//  these are children of a session rather than peers of one.
//

import Foundation

struct SubagentActivity: Identifiable, Equatable, ToolTracking {
    let agentID: String
    var id: String { agentID }

    /// `Explore`, `fork`, `general-purpose`, … Optional because a tool call can be the first we hear of
    /// an agent, and `agent_type` is not guaranteed on every event.
    var agentType: String?

    /// Never `.idle`. An agent is working, blocked, finished or failed — it exits when its work is done,
    /// so there is no state for sitting around, which is exactly what `idle` means for a session.
    var state: SessionState = .working

    var startedAt: Date
    /// Set by `SubagentStop`. Also what `SessionStore.tick()` measures the display decay from.
    var finishedAt: Date?

    var currentTool: String?
    var currentToolSummary: String?
    var toolCounts: [String: Int] = [:]
    /// Its own history, not its session's. Mixing the two is what made the session's adaptive stall
    /// threshold an average over execution contexts that have nothing to do with each other.
    var toolDurations = ToolDurations()
    var lastProgressAt: Date?
    var currentToolWasBlocked = false

    /// From `SubagentStop`'s `last_assistant_message` — what this agent concluded, which is the whole
    /// reason a finished child is worth keeping on screen at all.
    var lastMessage: String?

    init(agentID: String, agentType: String? = nil, startedAt: Date) {
        self.agentID = agentID
        self.agentType = agentType
        self.startedAt = startedAt
    }

    var isFinished: Bool { finishedAt != nil }

    /// One line describing what this agent is doing, or what it concluded. Same contract as
    /// `Session.activityLine(now:)`: the row has space for one line and no more.
    var activityLine: String? {
        switch state {
        case .working:
            guard let currentTool else { return nil }
            if let summary = currentToolSummary, summary != currentTool {
                return "\(currentTool) · \(summary)"
            }
            return currentTool
        case .needsYou:
            return currentToolSummary ?? currentTool
        case .done, .error:
            return lastMessage
        // Unreachable, but a `default` here would silently absorb a state added later.
        case .idle:
            return nil
        }
    }

    /// How long this agent has run: to its finish if it has one, otherwise to now.
    func elapsed(now: Date) -> TimeInterval {
        max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }
}
