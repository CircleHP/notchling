//
//  What `notchling-hook` writes into the spool. Our own format, not Claude Code's raw hook payload.
//

import Foundation

struct HookEvent: Decodable {
    /// The spool formats this build understands, matching `notchling-hook`.
    ///
    /// v1 carries no provider and means Claude by its silence — that is what a hook which knew of no
    /// other agent wrote. v2 names one. Anything else, and any v2 naming an agent this build does not
    /// know, is set aside rather than assumed: see `HookSpoolWatcher.setAside(_:)`.
    static let schemaVersion = 1
    static let providerSchemaVersion = 2

    var v: Int
    var ts: Double
    var event: String
    var sessionId: String

    var pid: Int32?
    /// When the process behind `pid` started. See `startTime(of:)` in `notchling-hook`.
    var pidStartedAt: Double?
    var cwd: String?
    var promptId: String?
    var agentId: String?
    var agentType: String?
    var agentTranscriptPath: String?

    var notificationType: String?
    var message: String?
    var toolName: String?
    var toolSummary: String?
    var lastMessage: String?
    var userInput: String?
    var source: String?
    /// The agent named on the wire, as written. Kept as a string rather than a `Provider` so a name
    /// this build does not know is a value it can *reject*: decoding straight into the enum would fail
    /// the whole event and look like a corrupt file rather than an unsupported agent.
    var provider: String?
    var reason: String?
    var errorMessage: String?
    var transcriptPath: String?

    var focusURL: String?
    var warpSessionId: String?
    var termProgram: String?
    var hostBundleId: String?

    var date: Date { Date(timeIntervalSince1970: ts) }

    /// Which agent wrote this event, or nil when the spool named one this build does not know.
    ///
    /// Reading an unknown agent as Claude is the failure worth designing against: it would put that
    /// session on a Claude row and send the transcript reader into `~/.claude/projects` after a file
    /// that does not exist.
    var resolvedProvider: Provider? {
        switch v {
        case Self.schemaVersion: .claude
        case Self.providerSchemaVersion: provider.flatMap(Provider.init(rawValue:))
        default: nil
        }
    }

    /// How the session this event describes is keyed in the store, or nil when its agent is unknown.
    var sessionKey: SessionKey? { resolvedProvider.map { SessionKey(provider: $0, id: sessionId) } }

    /// True when the event came from inside a subagent rather than the top-level session.
    var isSubagent: Bool { agentId != nil }
}
