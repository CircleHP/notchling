import Foundation
import Testing

@testable import Notchling

/// `statusline-usage.sh` from the repo, and whether the `jq` it needs is here. Skipped rather than
/// failed when either is missing, like the hook-binary tests.
private let statusLineScript: URL? = {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = repoRoot.appendingPathComponent("statusline-usage.sh")
    guard FileManager.default.isExecutableFile(atPath: script.path) else { return nil }
    return FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/jq")
        || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/jq")
        || FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")
        ? script : nil
}()

/// The two halves of the usage path meeting: what the status line writes, read back by the app.
/// Neither side proves much alone — the arbitration tests use handwritten JSON, and the script test
/// would only prove it wrote *something*.
@Suite(
    "statusline-usage.sh",
    .enabled(if: statusLineScript != nil, "statusline-usage.sh or jq is not available")
)
@MainActor
struct StatusLineScriptTests {
    private func render(session: String, fiveHour: Double, home: URL) throws {
        let payload: [String: Any] = [
            "session_id": session,
            "model": ["display_name": "Opus"],
            "workspace": ["current_dir": "/tmp/project"],
            "context_window": ["used_percentage": 12, "context_window_size": 200_000],
            "cost": ["total_lines_added": 1, "total_lines_removed": 0],
            "rate_limits": [
                "five_hour": ["used_percentage": fiveHour, "resets_at": 99_999_999],
                "seven_day": ["used_percentage": 11, "resets_at": 99_999_999],
            ],
        ]

        let process = Process()
        process.executableURL = try #require(statusLineScript)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment

        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    @Test("two sessions each keep their own reading, and the app resolves them to the higher one")
    func twoSessionsDoNotOverwriteEachOther() throws {
        let home = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        // The busy session first, then an idle one rendering a reading of its own that is older
        // however recently it was written. This is the order that used to lose.
        try render(session: "sess-busy", fiveHour: 62, home: home)
        try render(session: "sess-idle", fiveHour: 41, home: home)

        let directory = home.appendingPathComponent(".notchling/usage")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["sess-busy.json", "sess-idle.json"], "one file per session, neither clobbered")

        let snapshot = try #require(
            UsageReader.read(in: directory, legacy: home.appendingPathComponent("nothing.json"))
        )
        #expect(snapshot.fiveHour?.usedPercentage == 62)

        // And the shared file still carries whoever wrote last, which is what a widget from before
        // this change reads.
        let shared = try #require(UsageReader.read(from: home.appendingPathComponent(".notchling/usage.json")))
        #expect(shared.fiveHour?.usedPercentage == 41)
    }
}
