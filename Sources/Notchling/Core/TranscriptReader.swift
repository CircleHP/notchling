//
//  Reads the two things Claude Code knows about a session that exist nowhere else: the title it
//  derives from the conversation — what `claude --resume` lists — and the colour a user sets with
//  `/color`.
//
//  Neither is in the session registry. Both are entries in the session's own transcript:
//
//      {"type":"ai-title","aiTitle":"Ship app via Homebrew instead of source","sessionId":"…"}
//      {"type":"agent-color","agentColor":"green","sessionId":"…"}
//
//  Rewritten as they change, so the last entry of each type wins. The transcript is append-only and
//  can reach tens of megabytes, so it is read backwards in bounded chunks and never parsed whole.
//

import Foundation

struct TranscriptMarks: Equatable {
    var title: String?
    var colorName: String?

    var isEmpty: Bool { title == nil && colorName == nil }
}

@MainActor
final class TranscriptReader {
    /// Read from the end in chunks this size, stopping as soon as both marks are found.
    nonisolated static let chunkSize = 256 * 1024
    /// A colour set at the start of a long session is a long way back, but not unboundedly so. Past
    /// this, treat it as absent rather than reading an entire conversation off disk.
    nonisolated static let maxBytesScanned = 4 * 1024 * 1024

    private let queue = DispatchQueue(label: "local.notchling.transcript", qos: .utility)
    private var inFlight: Set<String> = []
    /// Modification date of the last transcript read, per session. Transcripts grow constantly, so
    /// re-reading an unchanged one is pure waste.
    private var lastModified: [String: Date] = [:]

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
    func read(sessionID: String, path: String, completion: @escaping (TranscriptMarks) -> Void) {
        guard !inFlight.contains(sessionID) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let modified = attributes?[.modificationDate] as? Date else { return }
        guard lastModified[sessionID] != modified else { return }

        inFlight.insert(sessionID)
        queue.async {
            let marks = Self.marks(inFileAt: path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight.remove(sessionID)
                self.lastModified[sessionID] = modified
                guard !marks.isEmpty else { return }
                completion(marks)
            }
        }
    }

    /// Forget a session, so a transcript that is written again is read again.
    func forget(sessionID: String) {
        lastModified.removeValue(forKey: sessionID)
        inFlight.remove(sessionID)
    }

    // MARK: - Reading

    nonisolated static func marks(inFileAt path: String) -> TranscriptMarks {
        guard let handle = FileHandle(forReadingAtPath: path) else { return TranscriptMarks() }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return TranscriptMarks() }

        var found = TranscriptMarks()
        var offset = end
        var scanned = 0
        // A line straddling a chunk boundary would parse as two broken halves, so the leftover head of
        // each chunk is carried into the next one, which is read earlier in the file.
        var carry = Data()

        while offset > 0, scanned < maxBytesScanned, found.title == nil || found.colorName == nil {
            let size = UInt64(min(chunkSize, Int(offset)))
            offset -= size
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunk = try? handle.read(upToCount: Int(size))
            else { break }
            scanned += Int(size)

            var buffer = chunk
            buffer.append(carry)
            let lines = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            // The first piece may be a partial line unless this chunk starts the file.
            if offset > 0, let head = lines.first {
                carry = Data(head)
            } else {
                carry = Data()
            }
            let complete = offset > 0 ? lines.dropFirst() : lines[...]

            for line in complete.reversed() {
                guard !line.isEmpty else { continue }
                absorb(line: Data(line), into: &found)
                if found.title != nil, found.colorName != nil { break }
            }
        }

        return found
    }

    /// Only the two entry types matter, and only the newest of each — so a value already found is
    /// never overwritten by an older line.
    private nonisolated static func absorb(line: Data, into found: inout TranscriptMarks) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
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
