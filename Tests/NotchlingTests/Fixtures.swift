import Foundation

@testable import Notchling

/// Build a `HookEvent` the way the app really gets one: as JSON from the spool, through the decoder.
/// Going via JSON rather than a memberwise init means these tests also cover the decode path.
func hookEvent(
    _ event: String,
    session: String = "s1",
    at date: Date = Date(timeIntervalSince1970: 1_000_000),
    _ extras: [String: Any] = [:]
) -> HookEvent {
    var payload: [String: Any] = [
        "v": 1,
        "ts": date.timeIntervalSince1970,
        "event": event,
        "sessionId": session,
    ]
    payload.merge(extras) { _, new in new }
    let data = try! JSONSerialization.data(withJSONObject: payload)
    return try! JSONDecoder().decode(HookEvent.self, from: data)
}

/// Same idea for registry entries, which are decoded from `~/.claude/sessions/<pid>.json`.
func registryEntry(
    session: String = "s1",
    pid: Int32 = 4242,
    status: String? = nil,
    name: String? = nil,
    cwd: String? = nil,
    kind: String? = nil,
    jobId: String? = nil,
    statusUpdatedAt: Date? = nil
) -> RegistryEntry {
    var payload: [String: Any] = ["pid": Int(pid), "sessionId": session]
    if let status { payload["status"] = status }
    if let name { payload["name"] = name }
    if let cwd { payload["cwd"] = cwd }
    if let kind { payload["kind"] = kind }
    if let jobId { payload["jobId"] = jobId }
    // The registry reports epoch milliseconds.
    if let statusUpdatedAt { payload["statusUpdatedAt"] = statusUpdatedAt.timeIntervalSince1970 * 1000 }
    let data = try! JSONSerialization.data(withJSONObject: payload)
    return try! JSONDecoder().decode(RegistryEntry.self, from: data)
}

/// A clock the tests drive by hand, so every time-based rule is deterministic.
final class TestClock {
    private(set) var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        current = start
    }

    var now: () -> Date { { [self] in current } }

    func advance(_ seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

/// A pid that is certainly alive (us) and one that is certainly not.
let livePID = Int32(ProcessInfo.processInfo.processIdentifier)
let deadPID: Int32 = 0x7FFF_FFF0

/// Scratch directory for tests that need real files, cleaned up by the caller.
func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("notchling-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
