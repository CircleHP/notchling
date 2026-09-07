//
//  How long each tool has been taking in this session, so "taking too long" can be judged against
//  what this tool normally does rather than against one number for everything.
//
//  The old rule was absolute: no tool had started for 600 seconds. That made a twelve-minute test run
//  and a wedged session the same signal, and the threshold had to be set high enough for the slowest
//  legitimate tool — so a `Read` that never returned went unreported for ten minutes.
//
//  Where an agent reports a tool finishing, a call is tracked by the id the agent gave it and closed on
//  its own event, because an agent that runs two tools at once has two of them in flight. Where it does
//  not — Claude Code, whose `PostToolUse` is deliberately unregistered because its payload carries
//  `tool_output` and can be megabytes — a `PreToolUse` for the next tool is taken as proof the previous
//  one finished, and `Stop` closes the last one.
//

import Foundation

struct ToolDurations: Equatable {
    /// Kept per tool. Short so the estimate tracks the repository it is in — a test suite that gets
    /// slower over an afternoon should drag the baseline with it.
    static let historyLength = 12

    /// Below this, "unusual" is not worth saying: tools are allowed a bad second.
    static let floor: TimeInterval = 45

    /// How far past the slowest run so far counts as unusual. Multiplying the *slowest* rather than the
    /// median is deliberately conservative — the cost of crying wolf is that the flag gets ignored.
    static let factor: Double = 3

    private var samples: [String: [TimeInterval]] = [:]

    mutating func record(_ duration: TimeInterval, for tool: String) {
        guard duration > 0, duration.isFinite else { return }
        var history = samples[tool] ?? []
        history.append(duration)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
        samples[tool] = history
    }

    /// The slowest run of this tool so far, or nil if it has never completed one.
    func longestSeen(for tool: String) -> TimeInterval? {
        samples[tool]?.max()
    }

    /// The point past which this tool is behaving unlike itself. Nil when there is no basis for an
    /// opinion, in which case the caller falls back to its absolute threshold.
    func unusualAfter(tool: String) -> TimeInterval? {
        guard let longest = longestSeen(for: tool) else { return nil }
        return max(Self.floor, longest * Self.factor)
    }
}

/// One tool call that has started and has not been reported finished.
///
/// Keyed by the id the agent gave the call, because that is the only thing that survives two of them
/// running at once — a name does not, and neither does "the latest one".
struct ActiveCall: Equatable {
    var tool: String
    var summary: String?
    var startedAt: Date
    /// Set when a human was deciding while this call was in flight. Its elapsed time then measures the
    /// person, not the tool, so it is discarded rather than recorded.
    var wasBlocked = false
}

/// The bookkeeping that turns a stream of "a tool started" events into per-tool durations.
///
/// Shared by `Session` and `SubagentActivity` because both track tools independently — and because the
/// rule below about *not* recording time spent behind a permission prompt is subtle enough that two
/// copies of it would eventually disagree.
protocol ToolTracking {
    var currentTool: String? { get set }
    var currentToolSummary: String? { get set }
    var lastProgressAt: Date? { get set }
    var currentToolWasBlocked: Bool { get set }
    var toolDurations: ToolDurations { get set }
    var toolCounts: [String: Int] { get set }
    /// Calls started and not yet reported finished, by the agent's own id for each. Empty throughout
    /// for an agent that reports no completions.
    var activeCalls: [String: ActiveCall] { get set }
}

extension ToolTracking {
    /// Close out the running tool, if the time it took says anything about the tool.
    mutating func recordCurrentToolDuration(endingAt end: Date) {
        defer { currentToolWasBlocked = false }
        guard let tool = currentTool, let startedAt = lastProgressAt, !currentToolWasBlocked else {
            return
        }
        toolDurations.record(end.timeIntervalSince(startedAt), for: tool)
    }

    /// Start a call the agent has identified, and let it name the row.
    mutating func beginCall(id: String, tool: String, summary: String?, at date: Date) {
        activeCalls[id] = ActiveCall(tool: tool, summary: summary, startedAt: date)
        currentTool = tool
        currentToolSummary = summary
    }

    /// Close the call the agent says finished, and hand the row to whatever is still running.
    ///
    /// Only this call: a second one may well still be in flight, and clearing the row on the first
    /// completion would blank a session that is still busy.
    mutating func endCall(id: String, at date: Date) {
        guard let call = activeCalls.removeValue(forKey: id) else { return }
        if !call.wasBlocked {
            toolDurations.record(date.timeIntervalSince(call.startedAt), for: call.tool)
        }
        nameRowFromActiveCalls(fallingBackTo: call)
    }

    /// A human is deciding, so every call in flight is now being timed against them rather than
    /// against itself.
    ///
    /// All of them, because the event that says so carries no call id — there is no way to tell which
    /// call the prompt belongs to. Discarding a good sample costs a data point; keeping an inflated one
    /// raises the stall threshold and suppresses the alert it exists to raise.
    mutating func markActiveCallsBlocked() {
        for id in activeCalls.keys { activeCalls[id]?.wasBlocked = true }
    }

    /// Give the row the call that started most recently — or, once nothing is running, keep naming the
    /// one that just finished.
    ///
    /// Keeping it is the point. An agent that reports completions reports them within a second of the
    /// call starting, and then thinks for half a minute before the next one; a row cleared on every
    /// completion names a tool for one second in thirty and reads as a session doing nothing. The last
    /// thing it did is the truest thing there is to say until it does something else, which is exactly
    /// what a row shows for an agent that reports no completions at all.
    mutating func nameRowFromActiveCalls(fallingBackTo finished: ActiveCall? = nil) {
        let latest = activeCalls.values.max { $0.startedAt < $1.startedAt } ?? finished
        currentTool = latest?.tool
        currentToolSummary = latest?.summary
    }

    /// What the running tool usually manages, when we have seen it finish before.
    var currentToolUsualDuration: TimeInterval? {
        currentTool.flatMap { toolDurations.longestSeen(for: $0) }
    }

    /// Tools used this turn, busiest first — e.g. `Edit ×3, Bash ×2`.
    var toolTally: String? {
        guard !toolCounts.isEmpty else { return nil }
        let parts = toolCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3)
            .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
