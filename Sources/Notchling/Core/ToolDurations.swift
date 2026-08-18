//
//  How long each tool has been taking in this session, so "taking too long" can be judged against
//  what this tool normally does rather than against one number for everything.
//
//  The old rule was absolute: no tool had started for 600 seconds. That made a twelve-minute test run
//  and a wedged session the same signal, and the threshold had to be set high enough for the slowest
//  legitimate tool — so a `Read` that never returned went unreported for ten minutes.
//
//  Durations come free from the event stream. `PostToolUse` is deliberately not registered (its payload
//  carries `tool_output`, which can be megabytes), but a `PreToolUse` for the next tool proves the
//  previous one finished, and `Stop` closes the last one.
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

/// The bookkeeping that turns a stream of "a tool started" events into per-tool durations.
///
/// Shared by `Session` and `SubagentActivity` because both track tools independently — and because the
/// rule below about *not* recording time spent behind a permission prompt is subtle enough that two
/// copies of it would eventually disagree.
protocol ToolTracking {
    var currentTool: String? { get set }
    var lastProgressAt: Date? { get set }
    var currentToolWasBlocked: Bool { get set }
    var toolDurations: ToolDurations { get set }
    var toolCounts: [String: Int] { get set }
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
