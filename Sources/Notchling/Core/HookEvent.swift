//
//  What `notchling-hook` writes into the spool. Our own format, not Claude Code's raw hook payload.
//

import Foundation

struct HookEvent: Decodable {
    var v: Int
    var ts: Double
    var event: String
    var sessionId: String

    var pid: Int32?
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
    var reason: String?
    var errorMessage: String?

    var focusURL: String?
    var warpSessionId: String?
    var termProgram: String?
    var hostBundleId: String?

    var date: Date { Date(timeIntervalSince1970: ts) }

    /// True when the event came from inside a subagent rather than the top-level session.
    var isSubagent: Bool { agentId != nil }
}
