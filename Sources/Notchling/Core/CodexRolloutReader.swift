//
//  The two numbers Codex knows about a session that its hooks never report: how full the context is,
//  and where the account's rate limits stand. The model is on every hook payload and is taken from
//  there instead; the effort is picked up here if a turn's context happens to be within reach.
//
//  Claude Code reports all of that through the status line it lets this widget install. Codex has no
//  such slot, and no payload carries a number — so the only place these exist is the session's own
//  rollout file, whose path every Codex hook event happens to name.
//
//  That file also contains the conversation, which this must never read. Three rules keep that from
//  being a matter of trust:
//
//  1. **A length cap first.** The records wanted here run to 3.7KB; a rollout's conversation records
//     reach 230KB. A line longer than `maxLineLength` is skipped without being looked at further, so
//     the lines that carry what someone said are discarded on their size alone.
//  2. **Then a substring test.** Only a line naming one of the two records is handed to a JSON
//     parser. Conversation text never reaches the decoder at all.
//  3. **Then an allowlist.** Two record types are read, and five fields out of them.
//
//  Read backwards from the end, because the newest reading is the one wanted and it is the last one
//  written, and stopping as soon as both records are found. A rollout grows for as long as a session
//  lives, so reading one forwards would mean reading all of it to answer a question the last kilobyte
//  already answers.
//

import Foundation

/// What one rollout last recorded.
struct CodexRollout: Equatable {
    var metrics: SessionMetrics?
    var usage: UsageReading?

    var isEmpty: Bool { metrics == nil && usage == nil }
}

/// How far a rollout has been examined, and what it yielded.
struct CodexRolloutScan: Equatable {
    var rollout: CodexRollout
    /// How big the file was when it was read. Two things turn on it: nothing below it is new ground, so
    /// the next scan stops there; and a file *smaller* than it was replaced rather than appended to,
    /// which is the one thing that makes everything known about it stop holding.
    var readTo: UInt64
}

@MainActor
final class CodexRolloutReader {
    /// Read backwards in chunks this size. Both records are within one of these of the end in
    /// practice — a turn writes them as it completes.
    nonisolated static let chunkSize = 64 * 1024

    /// How far back to look before treating the answer as absent. A session whose last turn ended
    /// long ago has both records much further back than this, and reading a megabyte to put a stale
    /// percentage on a row is not a trade worth making.
    nonisolated static let maxBytesScanned = 1024 * 1024

    /// A line longer than this cannot be one of the two records — the longest observed is 3.7KB — so
    /// it is dropped without being examined. This is what keeps the conversation out: its records run
    /// to two hundred kilobytes and are refused on length before anything parses them.
    nonisolated static let maxLineLength = 8 * 1024

    private let queue = DispatchQueue(label: "local.notchling.rollout", qos: .utility)
    private var inFlight: Set<SessionKey> = []
    /// Modification date of the last read, per session. A rollout grows on every message, and
    /// re-reading an unchanged one is pure waste.
    private var lastModified: [SessionKey: Date] = [:]
    private var progress: [SessionKey: CodexRolloutScan] = [:]

    /// Reads off the main thread and answers on it. Does nothing while a read for the same session is
    /// already running, or when the file has not changed since the last one.
    func read(
        key: SessionKey,
        path: String,
        completion: @escaping @MainActor @Sendable (CodexRollout) -> Void
    ) {
        guard !inFlight.contains(key) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let modified = attributes?[.modificationDate] as? Date else { return }
        guard lastModified[key] != modified else { return }

        inFlight.insert(key)
        let previous = progress[key]
        queue.async {
            let scan = Self.scan(fileAt: path, after: previous)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight.remove(key)
                self.lastModified[key] = modified
                self.progress[key] = scan
                guard !scan.rollout.isEmpty, scan.rollout != previous?.rollout else { return }
                completion(scan.rollout)
            }
        }
    }

    func forget(key: SessionKey) {
        lastModified.removeValue(forKey: key)
        progress.removeValue(forKey: key)
        inFlight.remove(key)
    }

    // MARK: - Reading

    /// Reads backwards from the end, far enough to answer and no further.
    ///
    /// `previous` is what the last scan found. Unlike the transcript marks next door, a stale reading
    /// here is worse than none — a context percentage from ten minutes ago is a number that looks
    /// current and is not — so what it carries forward is only used where the new ground says nothing
    /// at all, and `SessionMetrics.isStale` still has the last word on the row.
    nonisolated static func scan(fileAt path: String, after previous: CodexRolloutScan?) -> CodexRolloutScan {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return previous ?? CodexRolloutScan(rollout: CodexRollout(), readTo: 0)
        }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else {
            return previous ?? CodexRolloutScan(rollout: CodexRollout(), readTo: 0)
        }

        // A file smaller than when it was last read was replaced rather than appended to, so nothing
        // known about it holds.
        let carried = (previous?.readTo ?? 0) > end ? nil : previous

        var found = CodexRollout()
        var offset = end
        var scanned = 0
        var carry = Data()

        // Nothing below where the last scan reached is new: it was read then, and what it found is
        // carried in below. A chunk straddling this still gets read whole, because a chunk is measured
        // back from the offset above rather than forward from here — which is what keeps a record
        // written across the boundary from being read as two broken halves.
        let floor = carried?.readTo ?? 0

        // The two numbers are what this is for. Effort is opportunistic: it is worth having if a turn's
        // context is in a chunk already read, and never worth another chunk of its own.
        while offset > floor, scanned < maxBytesScanned,
              found.metrics?.contextUsedPercent == nil || found.usage == nil {
            let size = UInt64(min(UInt64(chunkSize), offset))
            offset -= size
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunk = try? handle.read(upToCount: Int(size))
            else { break }
            scanned += Int(size)

            var buffer = chunk
            buffer.append(carry)
            let lines = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            // The first piece may be a partial line unless this chunk starts the file. Carried only
            // while it could still become one of ours; past the cap it never can.
            if offset > 0, let head = lines.first, head.count <= maxLineLength {
                carry = Data(head)
            } else {
                carry = Data()
            }
            let complete = offset > 0 ? lines.dropFirst() : lines[...]

            // Every line of the chunk, not up to the first answer. Reading backwards, a turn's context
            // sits *earlier* in the file than the token count that closes the turn — so stopping at the
            // first record found would step over it every time. The bytes are already in hand; the
            // decision worth making is whether to fetch another chunk, which the loop above makes.
            for line in complete.reversed() {
                absorb(line: line, into: &found)
            }
        }

        // On the percentage rather than on the reading as a whole, and for the same reason as the guard
        // in `absorbTokenCount`: a `turn_context` record makes `metrics` non-nil carrying only the
        // effort, and a carry keyed on `metrics == nil` then dropped a percentage the last scan had
        // already found — writing nil onto the row for the length of the turn being watched.
        //
        // Its own stamp comes with it, so `SessionMetrics.isStale` can still retire a reading that has
        // stopped being true.
        if found.metrics?.contextUsedPercent == nil,
           let previous = carried?.rollout.metrics, previous.contextUsedPercent != nil {
            let effort = found.metrics?.effort ?? previous.effort
            found.metrics = previous
            found.metrics?.effort = effort
        }
        if found.usage == nil { found.usage = carried?.rollout.usage }
        // Effort does not change within a session, so once seen it is kept rather than looked for again.
        if found.metrics?.effort == nil, let effort = carried?.rollout.metrics?.effort {
            found.metrics?.effort = effort
        }

        return CodexRolloutScan(rollout: found, readTo: end)
    }

    /// The three filters, in the order that matters: length, then name, then shape.
    private nonisolated static func absorb(line: some Collection<UInt8>, into found: inout CodexRollout) {
        guard !line.isEmpty, line.count <= maxLineLength else { return }

        let data = Data(line)
        let isTokenCount = data.contains(Self.tokenCountMarker)
        let isTurnContext = data.contains(Self.turnContextMarker)
        guard isTokenCount || isTurnContext else { return }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return }

        let stamp = (object["timestamp"] as? String).flatMap(Self.timestamp(from:)) ?? Date.now

        // Both checked against the record's own type, not against the substring that got the line this
        // far: a short record of some other kind could carry the same word and an `info` object.
        if isTokenCount, payload["type"] as? String == "token_count" {
            absorbTokenCount(payload, at: stamp, into: &found)
        }
        if isTurnContext, object["type"] as? String == "turn_context" {
            absorbTurnContext(payload, at: stamp, into: &found)
        }
    }

    private nonisolated static func absorbTokenCount(
        _ payload: [String: Any],
        at stamp: Date,
        into found: inout CodexRollout
    ) {
        if found.usage == nil, let limits = payload["rate_limits"] as? [String: Any] {
            let reading = UsageReading(
                fiveHour: window(limits["primary"]),
                sevenDay: window(limits["secondary"]),
                // The rollout's own timestamp, not now: unlike Claude's status line, which writes
                // whenever it renders, this line was written when the reading was taken.
                writtenAt: stamp
            )
            if reading.fiveHour != nil || reading.sevenDay != nil { found.usage = reading }
        }

        // On the field wanted, not on the whole reading. A turn's context is written *before* the token
        // count that closes the turn, so reading backwards during a turn in progress finds a reading
        // carrying only the effort — and a guard on the reading itself skips the numbers for as long as
        // that turn lasts.
        guard found.metrics?.contextUsedPercent == nil,
              let info = payload["info"] as? [String: Any]
        else { return }
        let window = (info["model_context_window"] as? NSNumber)?.intValue
        let used = ((info["last_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber)?.intValue

        found.metrics = SessionMetrics(
            contextUsedPercent: contextUsedPercent(tokens: used, window: window),
            contextWindowSize: window,
            model: nil,
            effort: found.metrics?.effort,
            linesAdded: nil,
            linesRemoved: nil,
            updatedAt: stamp
        )
    }

    /// Only the effort. The model is on every hook payload, which is both cheaper to read and current
    /// for a session whose rollout has grown past what this will look through.
    private nonisolated static func absorbTurnContext(
        _ payload: [String: Any],
        at stamp: Date,
        into found: inout CodexRollout
    ) {
        guard let effort = payload["effort"] as? String else { return }
        var metrics = found.metrics ?? SessionMetrics(updatedAt: stamp)
        if metrics.effort == nil { metrics.effort = effort }
        found.metrics = metrics
    }

    /// Codex's own calculation, ported so the row and `/status` agree rather than nearly agree.
    ///
    /// The baseline is the context a session starts with before anyone has said anything — the system
    /// prompt and the tool definitions — and it is subtracted from both sides. Without it a fresh
    /// session reads as several per cent used, which is true of the window and not of the person.
    nonisolated static let baselineTokens = 12_000

    nonisolated static func contextUsedPercent(tokens: Int?, window: Int?) -> Double? {
        guard let tokens, let window else { return nil }
        let effective = window - baselineTokens
        guard effective > 0 else { return nil }
        let used = max(0, tokens - baselineTokens)
        let remaining = max(0, effective - used)
        let remainingPercent = (Double(remaining) / Double(effective) * 100).rounded()
        return min(100, max(0, 100 - remainingPercent))
    }

    private nonisolated static func window(_ limit: Any?) -> UsageWindow? {
        guard let limit = limit as? [String: Any],
              let percent = (limit["used_percent"] as? NSNumber)?.doubleValue
        else { return nil }
        return UsageWindow(
            usedPercentage: min(100, max(0, percent)),
            resetsAt: (limit["resets_at"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
        )
    }

    private nonisolated static let tokenCountMarker = Data(#""token_count""#.utf8)
    private nonisolated static let turnContextMarker = Data(#""turn_context""#.utf8)

    /// Built per call rather than held: `ISO8601DateFormatter` is not `Sendable`, and this runs once per
    /// record a scan looks at, of which there are a handful in the chunk it reads.
    private nonisolated static func timestamp(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
