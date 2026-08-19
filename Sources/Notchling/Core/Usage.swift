//
//  Plan rate limits — the 5-hour and 7-day windows, as reported by the server rather than estimated
//  from token counts.
//
//  Claude Code hands `rate_limits.*` to the status line and nowhere else: no hook payload carries it
//  and nothing under `~/.claude` caches it. That is why `statusline-usage.sh` exists — and why these
//  numbers only refresh while a session is on screen, which `isStale` exists to admit.
//

import Foundation

struct UsageWindow: Equatable {
    /// 0–100.
    var usedPercentage: Double
    var resetsAt: Date?

    var remainingPercentage: Double { max(0, 100 - usedPercentage) }

    /// The reset time has passed, so these numbers describe a window that no longer exists.
    var hasReset: Bool {
        guard let resetsAt else { return false }
        return resetsAt <= .now
    }

    /// `2h10m`, `14m`, or nil when there is no reset time.
    var resetLabel: String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSinceNow
        guard seconds > 0 else { return "now" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours >= 24 { return "\(hours / 24)d\(hours % 24)h" }
        if hours > 0 { return "\(hours)h\(String(format: "%02d", minutes))m" }
        return "\(minutes)m"
    }
}

struct UsageSnapshot: Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var updatedAt: Date

    static let stalenessThreshold: TimeInterval = 30 * 60

    var isStale: Bool {
        Date.now.timeIntervalSince(updatedAt) > Self.stalenessThreshold
    }

    var hasAnything: Bool { fiveHour != nil || sevenDay != nil }
}

// MARK: - Reading

/// On-disk format written by `statusline-usage.sh`.
private struct UsageFile: Decodable {
    var v: Int
    var ts: Double
    var fiveHourUsedPercent: Double?
    var fiveHourResetsAt: Double?
    var sevenDayUsedPercent: Double?
    var sevenDayResetsAt: Double?
}

/// What one session's status line last saw. Plan limits are account-wide, so several of these
/// describe the same two windows from different moments.
struct UsageReading: Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?

    /// When the status line wrote this — which is *not* when the server measured it. A session that
    /// has been idle for twenty minutes still renders on its timer, carrying the rate limits from
    /// its own last response, and writes them with a timestamp of now.
    var writtenAt: Date
}

@MainActor
enum UsageReader {
    nonisolated static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".notchling")
        .appendingPathComponent("usage")

    /// Usage files that did not decode last time, so each is reported once. See `readAll(in:)`.
    private static var unreadable: Set<String> = []

    nonisolated static let path = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".notchling")
        .appendingPathComponent("usage.json")

    /// Every session's reading, arbitrated into one answer.
    ///
    /// Falls back to the single shared file when no session has written yet, which is the window
    /// straight after an upgrade: the directory is empty until the next status line renders, and
    /// dropping the bars for that minute would look like a regression.
    static func read(in dir: URL = directory, legacy: URL = path) -> UsageSnapshot? {
        let readings = readAll(in: dir)
        if let snapshot = arbitrate(readings) { return snapshot }
        return read(from: legacy)
    }

    static func readAll(in dir: URL = directory) -> [UsageReading] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return [] }

        let decoder = JSONDecoder()
        var readings: [UsageReading] = []

        // Once per file, not once per sweep: this is read every two seconds, and a status line
        // whose output has changed shape would otherwise repeat itself all day.
        var stillUnreadable: Set<String> = []

        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let file = try? decoder.decode(UsageFile.self, from: data),
                  file.v == 1
            else {
                stillUnreadable.insert(name)
                if !unreadable.contains(name) {
                    Log.usage.error(
                        """
                        usage/\(name, privacy: .public) is not readable as a usage file — the status \
                        line's output may have changed, and the plan bars will stop moving
                        """
                    )
                }
                continue
            }

            let reading = UsageReading(
                fiveHour: window(file.fiveHourUsedPercent, file.fiveHourResetsAt),
                sevenDay: window(file.sevenDayUsedPercent, file.sevenDayResetsAt),
                writtenAt: Date(timeIntervalSince1970: file.ts)
            )
            if reading.fiveHour != nil || reading.sevenDay != nil { readings.append(reading) }
        }

        unreadable = stillUnreadable
        return readings
    }

    /// Picks one answer out of however many sessions are running.
    ///
    /// Each window is decided on its own, and not by who wrote last: the files record write time,
    /// not measurement time, so they cannot be ordered by their own timestamps. What can be ordered
    /// is the content. Usage only accumulates inside a window, so of two readings of the same window
    /// the higher one is the later measurement; and a `resetsAt` further ahead means the window
    /// rolled over, which is the one thing that makes a smaller number the newer one.
    ///
    /// The stamp is the most recent write from any session, because that is what staleness is about
    /// — whether anything is still reporting — rather than which reading won.
    static func arbitrate(_ readings: [UsageReading]) -> UsageSnapshot? {
        guard let writtenAt = readings.map(\.writtenAt).max() else { return nil }

        let snapshot = UsageSnapshot(
            fiveHour: latest(readings.compactMap(\.fiveHour)),
            sevenDay: latest(readings.compactMap(\.sevenDay)),
            updatedAt: writtenAt
        )
        return snapshot.hasAnything ? snapshot : nil
    }

    private static func latest(_ windows: [UsageWindow]) -> UsageWindow? {
        windows.max { left, right in
            let leftReset = left.resetsAt ?? .distantPast
            let rightReset = right.resetsAt ?? .distantPast
            if leftReset != rightReset { return leftReset < rightReset }
            return left.usedPercentage < right.usedPercentage
        }
    }

    private static func window(_ percent: Double?, _ resets: Double?) -> UsageWindow? {
        guard let percent else { return nil }
        return UsageWindow(
            usedPercentage: min(100, max(0, percent)),
            resetsAt: resets.map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// A session that ended leaves its last reading behind. Harmless while its window is current —
    /// arbitration drops it as soon as a newer `resetsAt` appears — but there is no reason to keep
    /// it for ever.
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

    /// The single shared file, written by every session and last-writer-wins. Kept only for the
    /// fallback above.
    static func read(from url: URL) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(UsageFile.self, from: data),
              file.v == 1
        else { return nil }

        let snapshot = UsageSnapshot(
            fiveHour: window(file.fiveHourUsedPercent, file.fiveHourResetsAt),
            sevenDay: window(file.sevenDayUsedPercent, file.sevenDayResetsAt),
            updatedAt: Date(timeIntervalSince1970: file.ts)
        )
        return snapshot.hasAnything ? snapshot : nil
    }
}
