//
//  Per-session context usage and model. Same story as Usage.swift: the status line is the only place
//  Claude Code reports these, and it receives them alongside a `session_id`.
//
//  One file per session id rather than one shared file, so two sessions writing at the same moment
//  cannot race each other.
//

import Foundation

struct SessionMetrics: Equatable {
    var contextUsedPercent: Double?
    var contextWindowSize: Int?
    var model: String?
    var effort: String?
    var linesAdded: Int?
    var linesRemoved: Int?
    var updatedAt: Date

    /// Older than this is treated as unknown rather than shown as current.
    static let stalenessThreshold: TimeInterval = 10 * 60

    var isStale: Bool {
        Date.now.timeIntervalSince(updatedAt) > Self.stalenessThreshold
    }

    /// `1M` / `200k`, for the context tooltip.
    var contextWindowLabel: String? {
        guard let size = contextWindowSize, size > 0 else { return nil }
        if size >= 1_000_000 { return "\(size / 1_000_000)M" }
        return "\(size / 1000)k"
    }
}

// MARK: - Reading

private struct SessionMetricsFile: Decodable {
    var v: Int
    var ts: Double
    var sessionId: String?
    var contextUsedPercent: Double?
    var contextWindowSize: Int?
    var model: String?
    var effort: String?
    var linesAdded: Int?
    var linesRemoved: Int?
}

@MainActor
enum SessionMetricsReader {
    nonisolated static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".notchling")
        .appendingPathComponent("sessions")

    /// Every session's metrics, keyed by session id. A handful of ~200-byte files.
    static func readAll(in dir: URL = directory) -> [String: SessionMetrics] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else {
            return [:]
        }

        let decoder = JSONDecoder()
        var result: [String: SessionMetrics] = [:]

        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let file = try? decoder.decode(SessionMetricsFile.self, from: data),
                  file.v == 1
            else { continue }

            // Trust the id inside the file over the filename.
            let id = file.sessionId ?? String(name.dropLast(".json".count))
            result[id] = SessionMetrics(
                contextUsedPercent: file.contextUsedPercent,
                contextWindowSize: file.contextWindowSize,
                model: file.model,
                effort: file.effort,
                linesAdded: file.linesAdded,
                linesRemoved: file.linesRemoved,
                updatedAt: Date(timeIntervalSince1970: file.ts)
            )
        }

        return result
    }

    /// Called once at launch; doing it on a timer would mean stat-ing the directory forever.
    static func pruneStaleFiles(in dir: URL = directory, olderThan age: TimeInterval = 3 * 24 * 60 * 60) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
        let cutoff = Date.now.addingTimeInterval(-age)

        for name in names {
            let url = dir.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}
