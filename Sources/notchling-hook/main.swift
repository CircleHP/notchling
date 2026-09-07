//
//  notchling-hook
//  Claude Code hook receiver. Reads a hook payload on stdin, keeps only the fields the widget needs,
//  adds terminal identity from its own environment (inherited from the Claude process), and drops one
//  JSON file into the spool directory the app watches.
//
//  Contract with the rest of the system:
//    - Never writes to stdout. Claude Code interprets stdout as hook output and can act on it.
//    - Never exits non-zero. A broken widget must not be able to break a session.
//    - Writes tmp-then-rename, so the watcher can never observe a partial file.
//

import Foundation
import os

/// The only channel this binary may complain on. stdout belongs to Claude Code, which acts on it,
/// and stderr is shown to the user — so a spool it cannot write to is otherwise silent, which is the
/// one failure worth knowing about. Same subsystem as the app; see `Log.swift` there.
let log = Logger(subsystem: "local.notchling", category: "hook")

let schemaVersion = 1

/// The spool format for an event that has to name the agent it came from.
///
/// v1 says Claude by its silence, so naming one needs a new version rather than a new optional field:
/// a build that predates providers ignores what it does not know, and would read a Codex event as a
/// Claude one — then go looking for its transcript under `~/.claude/projects`.
let providerSchemaVersion = 2
let spoolCap = 500
let maxMessageLength = 400
let maxToolSummaryLength = 120

/// Exit silently and successfully. Used for every failure path.
func giveUp() -> Never {
    exit(0)
}

/// Which agent's hooks are calling.
///
/// Passed in rather than read off the payload, because there is nothing in a payload to read: Codex's
/// wire event names are PascalCase and identical to Claude's for every event they share, and its field
/// names match too. The installer writes the answer into the command it registers.
enum Agent: String {
    case claude
    case codex

    /// What the process is called, for the walk up the parent chain. Matched against `p_comm`, which
    /// is `claude` and `codex` respectively.
    var executableName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }
}

let agent: Agent = {
    let flag = "--provider"
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    var named: String?
    while let argument = arguments.next() {
        if argument == flag {
            named = arguments.next()
        } else if argument.hasPrefix("\(flag)=") {
            named = String(argument.dropFirst(flag.count + 1))
        }
    }

    guard let named else { return .claude }
    guard let agent = Agent(rawValue: named) else {
        // Recording it as Claude would put another agent's session on a Claude row, and inventing a
        // name the app does not know only gets the event set aside. Saying so is the useful failure.
        log.error("unknown \(flag, privacy: .public) \(named, privacy: .public); nothing was recorded")
        giveUp()
    }
    return agent
}()

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard !stdinData.isEmpty,
      let root = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any]
else {
    giveUp()
}

func string(_ key: String, in dict: [String: Any] = root) -> String? {
    guard let value = dict[key] as? String, !value.isEmpty else { return nil }
    return value
}

func truncated(_ value: String?, to limit: Int) -> String? {
    guard let value else { return nil }
    let flat = value
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if flat.isEmpty { return nil }
    if flat.count <= limit { return flat }
    return String(flat.prefix(limit)) + "…"
}

guard let wireEvent = string("hook_event_name"), let sessionID = string("session_id") else {
    giveUp()
}

/// The spool has one vocabulary and it is ours, not any agent's. Codex's names already match Claude's
/// wherever the meaning matches, so exactly one needs translating.
///
/// `PermissionRequest` is Codex's dedicated event for a tool waiting on a person, which is what Claude
/// reports as a `Notification` carrying `permission_prompt`. Normalising it here rather than teaching
/// the store a second name for one meaning is what stops a missed case failing silently: an event the
/// store does not recognise reaches `default:` and the row simply never asks for attention — which is
/// the one thing this widget exists to do.
///
/// The events with no Claude equivalent — `PostToolUse`, `Interrupt`, `PreCompact`, `PostCompact` —
/// keep their own names, there being nothing to normalise them to.
let event: String = switch (agent, wireEvent) {
case (.codex, "PermissionRequest"): "Notification"
default: wireEvent
}

/// Codex has no `notification_type`, because `PermissionRequest` *is* the permission case. The field
/// it normalises onto has to be filled in here rather than read.
let isCodexPermissionRequest = agent == .codex && wireEvent == "PermissionRequest"

let notificationType: String? = isCodexPermissionRequest ? "permission_prompt" : string("notification_type")

/// Codex has no `message` either. What it does have, on a `PermissionRequest` alone, is the question it
/// is putting to the user — in `tool_input.description`, in its own words, written to be read by a
/// person. That is what a notification's message is for, so it goes there rather than being derived
/// from the tool name.
let message: String? = if isCodexPermissionRequest {
    (root["tool_input"] as? [String: Any])?["description"] as? String
} else {
    string("message")
}

/// A one-line gloss of what the tool is about to do, so the notch can show "Bash · npm test" instead
/// of a bare tool name. Each tool keeps its own most-identifying field.
func toolSummary(toolName: String?, toolInput: [String: Any]?) -> String? {
    guard let toolName, let toolInput else { return nil }
    let raw: String? = switch toolName {
    case "Bash", "BashOutput":
        (toolInput["description"] as? String) ?? (toolInput["command"] as? String)
    case "Read", "Write", "Edit", "NotebookEdit":
        (toolInput["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
    case "Grep":
        toolInput["pattern"] as? String
    case "Glob":
        toolInput["pattern"] as? String
    case "WebFetch":
        (toolInput["url"] as? String).flatMap { URL(string: $0)?.host }
    case "WebSearch":
        toolInput["query"] as? String
    case "Task", "Agent":
        (toolInput["description"] as? String) ?? (toolInput["subagent_type"] as? String)
    case "Skill":
        toolInput["skill"] as? String
    default:
        toolInput["description"] as? String
    }
    return truncated(raw, to: maxToolSummaryLength)
}

// Terminal identity comes from the environment, not the payload: Claude Code runs hooks with its own
// environment, and inherited these from the shell that launched it. That is how a widget outside the
// terminal learns which tab a session belongs to.
let environment = ProcessInfo.processInfo.environment

/// `CLAUDE_PID` is exported by Claude Code for its subprocesses. The parent walk covers a future
/// version that stops exporting it, and is the only route under any other agent: hooks are spawned
/// through a shell, so the agent is this process's parent or grandparent.
func resolveAgentPID() -> Int32? {
    // Claude Code's own export, and meaningless under anything else — a Codex hook that inherited a
    // stale `CLAUDE_PID` would name a Claude process as the owner of a Codex session, and every row
    // built on it would point at the wrong terminal.
    if agent == .claude, let raw = environment["CLAUDE_PID"], let pid = Int32(raw) { return pid }

    var candidate = getppid()
    for _ in 0 ..< 4 {
        guard candidate > 1 else { return nil }
        if processName(of: candidate)?.contains(agent.executableName) == true { return candidate }
        guard let parent = parentPID(of: candidate) else { return nil }
        candidate = parent
    }
    return nil
}

func sysctlProcInfo(_ pid: Int32) -> kinfo_proc? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
    guard result == 0, size > 0 else { return nil }
    return info
}

func parentPID(of pid: Int32) -> Int32? {
    sysctlProcInfo(pid)?.kp_eproc.e_ppid
}

/// When the process behind a pid started, as epoch seconds.
///
/// Sent alongside the pid because a pid on its own is not an identity: macOS reuses them, and by the
/// time the app drains this event — which can be minutes, if it was not running — the number may
/// belong to something else entirely. Read here rather than there because here it cannot be wrong:
/// this binary is a child of the agent, so the pid is certainly that process at this moment.
func startTime(of pid: Int32) -> Double? {
    guard let info = sysctlProcInfo(pid) else { return nil }
    let started = info.kp_proc.p_starttime
    guard started.tv_sec > 0 else { return nil }
    return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
}

func processName(of pid: Int32) -> String? {
    guard var info = sysctlProcInfo(pid) else { return nil }
    // No force unwrap: this binary runs on `PreToolUse`, in the hot path of every tool call in every
    // session, and its whole contract is that it cannot take a session down with it.
    return withUnsafeBytes(of: &info.kp_proc.p_comm) { bytes -> String? in
        guard let base = bytes.baseAddress else { return nil }
        return String(cString: base.assumingMemoryBound(to: CChar.self))
    }
}

// `nonisolated(unsafe)` on the two globals the helpers below touch. Under complete concurrency
// checking a global declared in `main.swift` is inferred main-actor isolated while the top-level
// statements around it are not, so the file cannot reach its own state without one side saying
// which it is. Unsafe in name only here: this binary reads stdin, writes one file and exits, on a
// single thread throughout.
nonisolated(unsafe) var out: [String: Any] = [
    "v": agent == .claude ? schemaVersion : providerSchemaVersion,
    "ts": Date().timeIntervalSince1970,
    "event": event,
    "sessionId": sessionID,
]

func put(_ key: String, _ value: Any?) {
    if let value { out[key] = value }
}

// Only on the version that carries one: see `providerSchemaVersion`.
if agent != .claude { put("provider", agent.rawValue) }

put("cwd", string("cwd"))
put("promptId", string("prompt_id"))
put("agentId", string("agent_id"))
put("agentType", string("agent_type"))

// `SubagentStop` only. Not read by the app, but the spool is the
// only place a subagent's own transcript is ever named, and dropping it here would mean re-deriving
// it later from an agent id we do not control the format of.
put("agentTranscriptPath", string("agent_transcript_path"))
// The session's own transcript, which is where Claude Code records the title it derives from the
// conversation and the colour set with `/color`. Forwarded rather than re-derived from cwd and id.
put("transcriptPath", string("transcript_path"))

put("notificationType", notificationType)
put("message", truncated(message, to: maxMessageLength))
put("toolName", string("tool_name"))
// Turn and call identity. The only way to tell one of several concurrent tool calls from another, and
// a spool event is the only place they are ever written down.
put("turnId", string("turn_id"))
put("toolUseId", string("tool_use_id"))
put("model", string("model"))
put("toolSummary", toolSummary(toolName: string("tool_name"), toolInput: root["tool_input"] as? [String: Any]))
put("lastMessage", truncated(string("last_assistant_message"), to: maxMessageLength))
// `UserPromptSubmit` calls this `prompt`; `user_input` is only a fallback. The distinction matters because
// reading the wrong key fails silently — the task text is simply always nil.
put("userInput", truncated(string("prompt") ?? string("user_input"), to: maxMessageLength))
put("source", string("source"))
put("reason", string("reason"))
// `PostToolUseFailure` calls this `error` — captured from a real payload, which carries
// `{"error": "Exit code 3", …}` and no `error_message` at all. `error_message` is kept as a fallback
// because `StopFailure` is an API-error event we cannot trigger on demand to check. Reading only the
// wrong key fails silently: the row shows `failed` and never says why.
put("errorMessage", truncated(string("error") ?? string("error_message"), to: maxMessageLength))

let agentPID = resolveAgentPID()
put("pid", agentPID.map { Int($0) })
put("pidStartedAt", agentPID.flatMap(startTime(of:)))
put("focusURL", environment["WARP_FOCUS_URL"])
put("warpSessionId", environment["WARP_TERMINAL_SESSION_UUID"])
put("termProgram", environment["TERM_PROGRAM"])
put("hostBundleId", environment["__CFBundleIdentifier"])

let spoolDirectory = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".notchling")
    .appendingPathComponent("events")

nonisolated(unsafe) let fileManager = FileManager.default
try? fileManager.createDirectory(
    at: spoolDirectory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
)

/// Keeps the spool bounded in case the app is never running to drain it: anything past its useful
/// life first, then the oldest of whatever is left until the count is under the cap.
///
/// Both passes are needed. Ten minutes of a busy session is more than `spoolCap` events on its own —
/// one per tool call — and an age cutoff alone would then delete nothing at all, which is exactly the
/// case this exists for.
///
/// Only finished event files count. A dotted `.tmp` belongs to another hook that is still writing,
/// and `failed/` is where the app sets aside events it could not read.
func pruneIfNeeded() {
    guard let entries = try? fileManager.contentsOfDirectory(atPath: spoolDirectory.path) else { return }

    // Millisecond-prefixed names, so this sort is chronological and the oldest are at the front.
    let files = entries.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
    guard files.count >= spoolCap else { return }

    let cutoff = Date().addingTimeInterval(-600)
    var survivors: [String] = []
    for name in files {
        let url = spoolDirectory.appendingPathComponent(name)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified > cutoff {
            survivors.append(name)
            continue
        }
        try? fileManager.removeItem(at: url)
    }

    guard survivors.count >= spoolCap else { return }
    for name in survivors.prefix(survivors.count - spoolCap + 1) {
        try? fileManager.removeItem(at: spoolDirectory.appendingPathComponent(name))
    }
}

// Sampled rather than run every time: this binary is on the hot path of every tool call. One readdir
// in ~32 invocations is plenty to keep the spool bounded.
if Int.random(in: 0 ..< 32) == 0 {
    pruneIfNeeded()
}

guard let payload = try? JSONSerialization.data(withJSONObject: out) else { giveUp() }

// Millisecond prefix so a plain directory sort is chronological; uuid suffix so two hooks firing in
// the same millisecond cannot collide.
let stamp = String(format: "%015.0f", Date().timeIntervalSince1970 * 1000)
let name = "\(stamp)-\(UUID().uuidString).json"
let temporary = spoolDirectory.appendingPathComponent(".\(name).tmp")
let final = spoolDirectory.appendingPathComponent(name)

do {
    try payload.write(to: temporary, options: .atomic)
    try fileManager.moveItem(at: temporary, to: final)
} catch {
    // Read-only spool, or a full disk. The widget goes quiet from here and nothing else says why.
    log.error("could not write to the spool: \((error as NSError).code, privacy: .public)")
    try? fileManager.removeItem(at: temporary)
}

exit(0)
