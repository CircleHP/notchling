import Foundation

enum SessionState: String, Equatable, Sendable {
    /// Mid-turn: thinking or running tools.
    case working
    /// Blocked on the human — a permission prompt, or a question asked mid-work.
    case needsYou
    /// Finished a turn. Decays to `idle` after `SessionStore.doneDecay`.
    case done
    case error
    /// Alive but nothing in flight.
    case idle

    /// Display order: the states that want attention sort first.
    var urgency: Int {
        switch self {
        case .needsYou: 0
        case .error: 1
        case .working: 2
        case .done: 3
        case .idle: 4
        }
    }

    var isNotifiable: Bool {
        switch self {
        case .needsYou, .done, .error: true
        case .working, .idle: false
        }
    }
}

enum SessionKind: String, Codable, Sendable {
    case interactive
    case bg
}

/// One Claude Code session, merged from the registry at `~/.claude/sessions/<pid>.json` and our
/// hook event spool.
struct Session: Identifiable, Equatable, ToolTracking {
    let sessionID: String
    var id: String { sessionID }

    var pid: Int32?
    var name: String?
    var cwd: String?
    var kind: SessionKind = .interactive
    var jobID: String?

    var state: SessionState = .idle
    /// When the *evidence* behind `state` was produced, used to arbitrate between the registry and
    /// the hook stream — whichever observed the session more recently wins.
    var stateSourceAt: Date = .distantPast
    /// When `state` last actually changed. Drives the `done` decay and the "for how long" label.
    var stateChangedAt: Date = .now

    var currentTool: String?
    var currentToolSummary: String?
    var toolCounts: [String: Int] = [:]
    /// How long each tool has taken here, used to judge whether the current one is running unusually
    /// long. See `ToolDurations`.
    var toolDurations = ToolDurations()
    /// Set when the current tool sat behind a permission prompt. Its elapsed time then includes however
    /// long a human took to answer, which is not a fact about the tool, so it is not recorded.
    var currentToolWasBlocked = false
    var turnStartedAt: Date?
    var lastMessage: String?
    var needsYouMessage: String?
    /// The last tool call that failed mid-turn. Kept separate from `lastMessage` because it must be
    /// visible without being notifiable: Claude retries and usually recovers, so a failing tool is
    /// progress, not an event anyone needs to be told about. Cleared when the next tool starts.
    var lastToolFailure: String?
    /// When this session last actually *finished* a turn. Not `stateChangedAt`, which for a settled
    /// session is when it went idle — twenty seconds after the fact. Cleared when a new turn starts, so a
    /// session that drifts to idle without finishing does not resurface an old one.
    var lastFinishedAt: Date?
    /// From `UserPromptSubmit`. The only record of what the session was asked to do; shown in the row
    /// tooltip, since the row itself only has room for what it is doing now.
    var lastPrompt: String?
    /// This session's subagents, keyed by agent id — running ones, plus finished ones for as long as
    /// they are still worth showing.
    var agents: [String: SubagentActivity] = [:]

    /// From the status line. Nil until it has run for this session.
    var metrics: SessionMetrics?

    /// The last sign of actual progress: a prompt submitted, or a tool starting. Deliberately not
    /// "any hook event" — a permission notification is not progress.
    var lastProgressAt: Date?
    /// The turn `lastProgressAt` belongs to, so a stall is reported at most once per turn.
    var currentPromptID: String?
    var isStalled = false

    var focusURL: String?
    var warpSessionID: String?
    var termProgram: String?
    var hostBundleID: String?
    var tty: String?
    var processCommand: String?

    /// From the registry: `"derived"` when Claude Code made the name up, absent when a person set it.
    var nameSource: String?
    /// The title Claude derives from the conversation — what `claude --resume` lists. Read from the
    /// transcript, because it is recorded nowhere else.
    var aiTitle: String?
    /// A colour set with `/color`, if one was. Absent for every session that never set one.
    var colorName: String?
    /// The session's own transcript, as the hook reported it.
    var transcriptPath: String?

    /// When this session first went missing from the registry snapshot, or nil while it is present.
    var missingFromRegistrySince: Date?

    /// When the registry started reporting this session continuously `idle`, or nil while it is
    /// busy. Used only to break a stuck `needsYou`.
    var registryIdleSince: Date?

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// A name someone chose beats one anything derived, and `notchling-1a` identifies nothing when
    /// three sessions are open. So: the user's name, then the title Claude derives from the
    /// conversation, then the registry's slug while the session is too young to have either.
    ///
    /// Background jobs keep the registry name unconditionally — for those it is the task's own title,
    /// which is already the best name available.
    var displayName: String {
        if let name, !name.isEmpty, nameSource != "derived" { return name }
        if kind != .bg, let aiTitle, !aiTitle.isEmpty { return aiTitle }
        if let name, !name.isEmpty { return name }
        if let cwd, !cwd.isEmpty { return URL(fileURLWithPath: cwd).lastPathComponent }
        return String(sessionID.prefix(8))
    }

    /// Display order for the subtree: oldest first, so an agent's position does not move when a sibling
    /// finishes. Ties broken by id, because two agents of a fan-out can share a start instant.
    var sortedAgents: [SubagentActivity] {
        agents.values.sorted {
            $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.agentID < $1.agentID
        }
    }

    var runningAgents: [SubagentActivity] { sortedAgents.filter { !$0.isFinished } }

    /// A fan-out in one line: how many agents, and how many have finished.
    ///
    /// This is what makes "wait or switch tabs" answerable at a glance, and it is deliberately on the
    /// *session's* line rather than only in the child rows — the panel caps how many agents it will draw,
    /// and the headline has to survive that cap.
    var agentSummary: String? {
        guard !agents.isEmpty else { return nil }
        let total = agents.count
        let finished = agents.values.filter(\.isFinished).count
        if finished == 0 { return total == 1 ? "1 agent" : "\(total) agents" }
        return "\(finished)/\(total) done"
    }

    var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// How long this session has shown no sign of progress, if it is working.
    ///
    /// A wedged session and a single long tool call are indistinguishable here, because the only
    /// completion signal is `PostToolUse` and that is deliberately not registered. So callers should
    /// report the elapsed time rather than claim the session is stuck.
    func stalledFor(now: Date = .now) -> TimeInterval? {
        guard state == .working, let lastProgressAt else { return nil }
        return now.timeIntervalSince(lastProgressAt)
    }

    /// How long this session may go without progress before it is worth mentioning.
    ///
    /// Judged against the running tool's own history where there is one, so a `Read` that has not
    /// returned in a minute is flagged while a test suite that always takes twelve is not. Falls back to
    /// `absolute` before the tool has ever completed here, and between a prompt and its first tool.
    func stallThreshold(absolute: TimeInterval) -> TimeInterval {
        guard let currentTool, let unusual = toolDurations.unusualAfter(tool: currentTool) else {
            return absolute
        }
        return unusual
    }

    func activityLine(now: Date = .now) -> String? {
        switch state {
        case .needsYou:
            return needsYouMessage ?? currentToolSummary ?? currentTool
        case .working:
            // While agents are out, the main thread is orchestrating, not running the tool the row would
            // otherwise name. `Task · 3/5 done` describes what is happening; `Task` on its own does not.
            if let agentSummary { return agentSummary }
            // Between a failed tool and whatever Claude tries next there is nothing else to say, and
            // saying nothing would hide the failure entirely.
            guard let currentTool else { return lastToolFailure }
            if let summary = currentToolSummary, summary != currentTool {
                return "\(currentTool) · \(summary)"
            }
            return currentTool
        case .done:
            return lastMessage
        case .error:
            return lastMessage ?? "failed"
        case .idle:
            return finishedAgo(now: now)
        }
    }

    /// How long ago this session finished, while that is still worth knowing.
    ///
    /// `done` decays to idle after twenty seconds so the mascot and the badge stop shouting, and until now
    /// that also threw away the fact — a session that had just finished looked exactly like one that had
    /// been cold for an hour. Past `finishedMemory` it stops mattering and the row goes quiet.
    func finishedAgo(now: Date = .now) -> String? {
        guard let lastFinishedAt else { return nil }
        let elapsed = now.timeIntervalSince(lastFinishedAt)
        guard elapsed >= 0, elapsed < Self.finishedMemory else { return nil }
        // Coarse on purpose: `done 4m00s ago` reads like a stopwatch, not like a memory.
        if elapsed < 60 { return "done just now" }
        return "done \(Int(elapsed / 60))m ago"
    }

    /// How long a finish stays worth mentioning. Beyond this it is history, not news.
    static let finishedMemory: TimeInterval = 30 * 60

    /// A pre-warmed background agent that has never been claimed. Cheap: no process lookup.
    var isUnclaimedSpare: Bool {
        kind == .bg && jobID != nil && name == jobID
    }

    /// One of Claude Code's pooled background processes, by argv.
    ///
    /// This is the reliable test and the name-based one above is not sufficient: a spare claimed for
    /// a job keeps that job's name in its registry file *after the job finishes*, while its process
    /// lives on as `claude bg-spare …`. Without this, a finished job shows up as an idle background
    /// session forever.
    var isPooledSpare: Bool {
        guard kind == .bg, let processCommand else { return false }
        return processCommand.contains("bg-spare") || processCommand.contains("bg-pty-host")
    }

    /// Claude Code plumbing rather than something the user started.
    var isInfrastructure: Bool { isUnclaimedSpare || isPooledSpare }
}
