//
//  Which agent CLI a session belongs to.
//
//  The widget observes a session in a terminal: a turn, some tool calls, a block on a human, a finish.
//  None of that is Claude Code's in particular, which is why nothing below this file names an agent. A
//  provider is not a behaviour — it is the set of *sources* a session's facts arrive from, and which of
//  those sources exist at all.
//

/// The agent CLI behind a session.
enum Provider: String, Codable, Sendable {
    case claude
    case codex

    var capabilities: Capabilities {
        switch self {
        case .claude: Capabilities(
                hasTranscriptMarks: true,
                hasStatusLineMetrics: true,
                hasToolCompletionEvents: false
            )
        case .codex: Capabilities(
                hasTranscriptMarks: false,
                hasStatusLineMetrics: false,
                hasToolCompletionEvents: true
            )
        }
    }
}

/// Which of the widget's sources exist for an agent.
///
/// Asked rather than the provider being named, so the store cannot come to contain a `switch provider`
/// — the one shape this seam exists to prevent. A flag here is a statement about a substrate, and it
/// flips the day that substrate appears without any view or rule changing.
struct Capabilities: Equatable, Sendable {
    /// A per-session transcript carrying the marks the widget reads: the title the agent derives from
    /// the conversation, a name a person set, and a colour. These are records in Claude Code's own
    /// transcript format, under `~/.claude/projects`.
    var hasTranscriptMarks: Bool

    /// A status line, installed by this widget, reporting context fill and cost per session. Claude
    /// Code has one slot for it; nothing else does.
    var hasStatusLineMetrics: Bool

    /// An event when a tool call finishes, identifying which call it was.
    ///
    /// Not registered for Claude Code, whose payload carries the tool's whole output; there, a call
    /// finishing is inferred from the next one starting. Where it *is* registered the inference is not
    /// needed and would be wrong, because the agent runs tools concurrently — two calls open at once
    /// makes "the next start ends the last call" attribute one tool's time to another.
    var hasToolCompletionEvents: Bool
}

/// How a session is identified everywhere it is used as a key.
///
/// A session id is unique within one agent and says nothing across two, so a bare id stops being a key
/// the moment there is a second provider. The environment cache, the transcript progress map and the
/// sound-cue dedupe are all keyed by session, and two providers sharing an id would cross-contaminate
/// every one of them — a row naming the wrong terminal, a title from another agent's transcript, a cue
/// swallowed because a different session had already played it.
///
/// `resolvedPIDs` is deliberately *not* keyed this way: a pid is the kernel's, already unique across
/// every process on the machine, and a session key there would let two rows each claim one probe of the
/// same process.
struct SessionKey: Hashable, Sendable {
    let provider: Provider
    let id: String

    /// A stable string for the two places that need one: SwiftUI row identity, and the composite
    /// session+turn key the stall cue dedupes on.
    var storageKey: String { "\(provider.rawValue):\(id)" }
}
