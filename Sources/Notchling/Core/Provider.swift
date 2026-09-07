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
