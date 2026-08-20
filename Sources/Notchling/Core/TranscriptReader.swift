//
//  Reads the two things Claude Code knows about a session that exist nowhere else: the title it
//  derives from the conversation — what `claude --resume` lists — and the colour a user sets with
//  `/color`.
//
//  Neither is in the session registry. Both are entries in the session's own transcript:
//
//      {"type":"ai-title","aiTitle":"Ship app via Homebrew instead of source","sessionId":"…"}
//      {"type":"agent-color","agentColor":"green","sessionId":"…"}
//      {"type":"custom-title","customTitle":"release work","sessionId":"…"}
//
//  Rewritten as they change, so the last entry of each type wins. The transcript is append-only and
//  can reach tens of megabytes, so it is read backwards in bounded chunks and never parsed whole.
//

import Foundation

struct TranscriptMarks: Equatable {
    /// The name a person set with `/rename` or `--name`. Claude Code writes this record only for a
    /// rename a person asked for: an `"auto"` rename appends an `ai-title` instead, and a collision
    /// rename touches nothing but the registry.
    var customTitle: String?
    var title: String?
    var colorName: String?

    var isEmpty: Bool { customTitle == nil && title == nil && colorName == nil }
    /// Nothing further back can change the answer, so the scan can stop.
    var isComplete: Bool { customTitle != nil && title != nil && colorName != nil }
}

/// How much of one transcript has been examined, and what it yielded.
struct TranscriptScan: Equatable {
    var marks: TranscriptMarks
    /// How big the file was when it was last read. Only what arrives above this can change the
    /// answer; everything below it is already summarised by `marks`.
    var readTo: UInt64
}

@MainActor
final class TranscriptReader {
    /// Read from the end in chunks this size, stopping as soon as every mark is found.
    nonisolated static let chunkSize = 256 * 1024
    /// A colour set at the start of a long session is a long way back, but not unboundedly so. Past
    /// this, treat it as absent rather than reading an entire conversation off disk.
    nonisolated static let maxBytesScanned = 4 * 1024 * 1024

    /// A line longer than this is not one of the three we are looking for, and carrying it between
    /// chunks is what would make a single enormous line cost more than the scan itself.
    nonisolated static let maxLineLength = 64 * 1024

    private let queue = DispatchQueue(label: "local.notchling.transcript", qos: .utility)
    private var inFlight: Set<String> = []
    /// Modification date of the last transcript read, per session. Transcripts grow constantly, so
    /// re-reading an unchanged one is pure waste.
    private var lastModified: [String: Date] = [:]
    /// What the last read found, and where the file ended when it found it.
    ///
    /// Without this every session missing any one mark re-reads the whole tail on every change: the
    /// scan only stops early when *every* mark is found, so a mark that is simply not in the file is
    /// never found and the search runs to its limit. Transcripts change on every message, so that is
    /// a few megabytes parsed every couple of seconds, for an answer that cannot have changed except
    /// in the bytes appended since.
    private var progress: [String: TranscriptScan] = [:]

    /// Where Claude Code keeps a session's transcript when the hook payload did not name it: the cwd
    /// with every `/` turned into `-`, under `~/.claude/projects`.
    nonisolated static func path(forSession sessionID: String, cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        let slug = cwd.replacingOccurrences(of: "/", with: "-")
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sessionID).jsonl")
            .path
    }

    /// Reads off the main thread and answers on it. Does nothing when the file has not changed since
    /// the last read, or when a read for the same session is already running.
    /// The callback is `@MainActor` because that is where it runs, and `@Sendable` because it
    /// travels through the queue to get there — the two together are what say "handed over, then
    /// called at home" rather than "called wherever it lands".
    func read(sessionID: String, path: String, completion: @escaping @MainActor @Sendable (TranscriptMarks) -> Void) {
        guard !inFlight.contains(sessionID) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let modified = attributes?[.modificationDate] as? Date else { return }
        guard lastModified[sessionID] != modified else { return }

        inFlight.insert(sessionID)
        let previous = progress[sessionID]
        queue.async {
            let scan = Self.scan(fileAt: path, after: previous)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight.remove(sessionID)
                self.lastModified[sessionID] = modified
                self.progress[sessionID] = scan
                guard !scan.marks.isEmpty, scan.marks != previous?.marks else { return }
                completion(scan.marks)
            }
        }
    }

    /// Forget a session, so a transcript that is written again is read again.
    func forget(sessionID: String) {
        lastModified.removeValue(forKey: sessionID)
        progress.removeValue(forKey: sessionID)
        inFlight.remove(sessionID)
    }

    // MARK: - Reading

    /// Reads backwards from the end, far enough to answer and no further.
    ///
    /// `previous` is what the last scan of this file returned: its `readTo` is where the file ended
    /// then, so only what arrived above it can change the answer.
    ///
    /// The newly arrived part is always read, whatever was already known. Every mark is *rewritten*
    /// as it changes — a second `/color` appends another entry rather than editing the first — so a
    /// scan that stopped because it already had them all would freeze a session's name, title and
    /// colour for the rest of its life. What the new region does not mention is filled in from `previous`, which
    /// is the only thing the earlier ground can still tell us.
    nonisolated static func scan(fileAt path: String, after previous: TranscriptScan?) -> TranscriptScan {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return previous ?? TranscriptScan(marks: TranscriptMarks(), readTo: 0)
        }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else {
            return previous ?? TranscriptScan(marks: TranscriptMarks(), readTo: 0)
        }

        // A file smaller than when it was last read was replaced rather than appended to, so nothing
        // known about it holds.
        let carried = (previous?.readTo ?? 0) > end ? nil : previous
        // Only the bytes that arrived since the last read can change the answer, plus one line of
        // overlap so an entry straddling the boundary is not missed by both scans. Without this the
        // scan walks back to the byte limit on every change to a file that changes every message.
        let boundary = carried?.readTo ?? 0
        let floor = boundary > UInt64(maxLineLength) ? boundary - UInt64(maxLineLength) : 0

        // Deliberately fresh rather than seeded with what is already known: `absorb` keeps the first
        // value it sees, reading backwards, so seeding it would make the older entry win.
        var found = TranscriptMarks()
        var offset = end
        var scanned = 0
        // A line straddling a chunk boundary would parse as two broken halves, so the leftover head of
        // each chunk is carried into the next one, which is read earlier in the file.
        var carry = Data()

        while offset > floor, scanned < maxBytesScanned, !found.isComplete {
            let size = UInt64(min(UInt64(chunkSize), offset - floor))
            offset -= size
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunk = try? handle.read(upToCount: Int(size))
            else { break }
            scanned += Int(size)

            var buffer = chunk
            buffer.append(carry)
            let lines = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            // The first piece may be a partial line unless this chunk starts the file.
            if offset > 0, let head = lines.first, head.count <= maxLineLength {
                carry = Data(head)
            } else {
                // Either the file starts here, or the partial line is longer than anything we are
                // looking for. Carrying that would grow without bound across chunks.
                carry = Data()
            }
            let complete = offset > 0 ? lines.dropFirst() : lines[...]

            for line in complete.reversed() {
                guard !line.isEmpty, line.count <= maxLineLength else { continue }
                absorb(line: Data(line), into: &found)
                if found.isComplete { break }
            }
        }

        // Whatever the new ground did not mention still stands from the last time it was read.
        if found.customTitle == nil { found.customTitle = carried?.marks.customTitle }
        if found.title == nil { found.title = carried?.marks.title }
        if found.colorName == nil { found.colorName = carried?.marks.colorName }

        return TranscriptScan(marks: found, readTo: end)
    }

    /// Only these three entry types matter, and only the newest of each — so a value already found is
    /// never overwritten by an older line.
    private nonisolated static func absorb(line: Data, into found: inout TranscriptMarks) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
        case "custom-title":
            if found.customTitle == nil, let name = object["customTitle"] as? String, !name.isEmpty {
                found.customTitle = name
            }
        case "ai-title":
            if found.title == nil, let title = object["aiTitle"] as? String, !title.isEmpty {
                found.title = title
            }
        case "agent-color":
            if found.colorName == nil, let colour = object["agentColor"] as? String, !colour.isEmpty {
                found.colorName = colour
            }
        default:
            break
        }
    }
}
