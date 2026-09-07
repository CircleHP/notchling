//
//  The name Codex derives for a session — what its `/status` calls the thread name, and the same kind
//  of thing as the title Claude Code records in a transcript. Without it a row falls back to the
//  working directory, which names the project rather than the work.
//
//  One shared append-only index rather than a file per session, so one read answers for every session
//  at once. An id appears in it more than once: the first entry a session writes is the prompt itself,
//  and the derived name replaces it seconds later —
//
//      {"id":"01a07c1f…","thread_name":"Whats the weather in Krakow today?","updated_at":"…47:08"}
//      {"id":"01a07c1f…","thread_name":"Check Krakow weather","updated_at":"…47:12"}
//
//  — so the *last* entry for an id is the answer. This reads backwards and keeps the first thing it
//  finds, which is the same thing.
//
//  Its location is derived from a session's own rollout path rather than from `CODEX_HOME`: that
//  variable belongs to a terminal, and a widget launched at login inherits nothing from one. The hook
//  reports the rollout absolutely, and the index sits four directories above it.
//
//  A name is all that is read. The index carries nothing else worth having, and the local database that
//  also holds one is not opened: it agrees with this file, and a schema is a heavier thing to depend on
//  than a line of JSON.
//

import Foundation

@MainActor
final class CodexNameReader {
    /// The index is measured in kilobytes — a hundred and fifty bytes an entry — so this covers more
    /// sessions than anyone has. Bounded anyway, because it is read on a timer.
    nonisolated static let maxBytesScanned = 256 * 1024

    /// A line longer than this is not one of these entries; the longest observed is 141 bytes.
    nonisolated static let maxLineLength = 4 * 1024

    private let queue = DispatchQueue(label: "local.notchling.codexnames", qos: .utility)
    private var inFlight = false
    private var lastModified: Date?

    /// `<home>/sessions/<year>/<month>/<day>/rollout-….jsonl` — so the home is four up, and the index
    /// sits in it.
    nonisolated static func indexPath(forRollout rollout: String) -> String? {
        var directory = URL(fileURLWithPath: rollout).deletingLastPathComponent()
        for _ in 0 ..< 4 {
            guard directory.pathComponents.count > 1 else { return nil }
            directory = directory.deletingLastPathComponent()
        }
        return directory.appendingPathComponent("session_index.jsonl").path
    }

    /// Reads off the main thread and answers on it. Does nothing while a read is already running, or
    /// when the file has not changed since the last one.
    func read(path: String, completion: @escaping @MainActor @Sendable ([String: String]) -> Void) {
        guard !inFlight else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let modified = attributes?[.modificationDate] as? Date else { return }
        guard lastModified != modified else { return }

        inFlight = true
        queue.async {
            let names = Self.scan(fileAt: path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight = false
                self.lastModified = modified
                guard !names.isEmpty else { return }
                completion(names)
            }
        }
    }

    // MARK: - Reading

    nonisolated static func scan(fileAt path: String) -> [String: String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [:] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [:] }

        let from = end > UInt64(maxBytesScanned) ? end - UInt64(maxBytesScanned) : 0
        guard (try? handle.seek(toOffset: from)) != nil,
              let data = try? handle.read(upToCount: Int(end - from))
        else { return [:] }

        var names: [String: String] = [:]
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)

        // Backwards, keeping the first entry seen for each id: the newest is the one that counts, and
        // the first partial line is dropped for the same reason every chunked read drops one.
        for line in lines.reversed() {
            guard line.count <= maxLineLength,
                  let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = entry["id"] as? String,
                  let name = entry["thread_name"] as? String,
                  !name.isEmpty,
                  names[id] == nil
            else { continue }
            names[id] = name
        }

        return names
    }
}
