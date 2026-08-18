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

@MainActor
enum UsageReader {
    nonisolated static let path = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".notchling")
        .appendingPathComponent("usage.json")

    /// Nil if the status line has never run. Read on the app's slow sweep — no watcher, because rate
    /// limits move on the order of minutes.
    static func read(from url: URL = path) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(UsageFile.self, from: data),
              file.v == 1
        else { return nil }

        func window(_ percent: Double?, _ resets: Double?) -> UsageWindow? {
            guard let percent else { return nil }
            return UsageWindow(
                usedPercentage: min(100, max(0, percent)),
                resetsAt: resets.map { Date(timeIntervalSince1970: $0) }
            )
        }

        let snapshot = UsageSnapshot(
            fiveHour: window(file.fiveHourUsedPercent, file.fiveHourResetsAt),
            sevenDay: window(file.sevenDayUsedPercent, file.sevenDayResetsAt),
            updatedAt: Date(timeIntervalSince1970: file.ts)
        )
        return snapshot.hasAnything ? snapshot : nil
    }
}
