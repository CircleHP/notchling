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

let schemaVersion = 1
let spoolCap = 500
let maxMessageLength = 400
let maxToolSummaryLength = 120

/// Exit silently and successfully. Used for every failure path.
func giveUp() -> Never {
    exit(0)
}

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

guard let event = string("hook_event_name"), let sessionID = string("session_id") else {
    giveUp()
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
/// version that stops exporting it: hooks are spawned through a shell, so Claude is this process's
/// parent or grandparent.
func resolveClaudePID() -> Int32? {
    if let raw = environment["CLAUDE_PID"], let pid = Int32(raw) { return pid }

    var candidate = getppid()
    for _ in 0 ..< 4 {
        guard candidate > 1 else { return nil }
        if processName(of: candidate)?.contains("claude") == true { return candidate }
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

func processName(of pid: Int32) -> String? {
    guard var info = sysctlProcInfo(pid) else { return nil }
    // No force unwrap: this binary runs on `PreToolUse`, in the hot path of every tool call in every
    // session, and its whole contract is that it cannot take a session down with it.
    return withUnsafeBytes(of: &info.kp_proc.p_comm) { bytes -> String? in
        guard let base = bytes.baseAddress else { return nil }
        return String(cString: base.assumingMemoryBound(to: CChar.self))
    }
}

var out: [String: Any] = [
    "v": schemaVersion,
    "ts": Date().timeIntervalSince1970,
    "event": event,
    "sessionId": sessionID,
]

func put(_ key: String, _ value: Any?) {
    if let value { out[key] = value }
}

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

put("notificationType", string("notification_type"))
put("message", truncated(string("message"), to: maxMessageLength))
put("toolName", string("tool_name"))
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

put("pid", resolveClaudePID().map { Int($0) })
put("focusURL", environment["WARP_FOCUS_URL"])
put("warpSessionId", environment["WARP_TERMINAL_SESSION_UUID"])
put("termProgram", environment["TERM_PROGRAM"])
put("hostBundleId", environment["__CFBundleIdentifier"])

let spoolDirectory = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".notchling")
    .appendingPathComponent("events")

let fileManager = FileManager.default
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
    try? fileManager.removeItem(at: temporary)
}

exit(0)
