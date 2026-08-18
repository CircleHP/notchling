//
//  Reads the session registry Claude Code maintains for itself at `~/.claude/sessions/<pid>.json`.
//
//  This is what makes the widget zero-configuration: every running session is listed there whether
//  or not our hooks are installed and whether or not the app was running when it started.
//
//  Undocumented, so treated defensively: every field beyond `sessionId` is optional and unknown
//  fields are ignored rather than failing the decode.
//

import Foundation

struct RegistryEntry: Decodable {
    var pid: Int32
    var sessionId: String
    var cwd: String?
    var name: String?
    var kind: String?
    var status: String?
    var jobId: String?
    var version: String?
    /// Epoch milliseconds.
    var statusUpdatedAt: Double?
    var updatedAt: Double?
    var startedAt: Double?

    var statusDate: Date? {
        (statusUpdatedAt ?? updatedAt).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

@MainActor
final class SessionRegistryReader {
    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude")
        .appendingPathComponent("sessions")

    private let queue = DispatchQueue(label: "local.notchling.registry", qos: .utility)
    private var watcher: DirectoryWatcher?
    private let onSnapshot: ([RegistryEntry]) -> Void

    init(onSnapshot: @escaping ([RegistryEntry]) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func start() {
        watcher = DirectoryWatcher(url: Self.directory, queue: queue) { [weak self] in
            Task { @MainActor in self?.scan() }
        }
        watcher?.start()
        scan()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Read every registry file and hand up a full snapshot. Also called on the app's slow timer —
    /// see `DirectoryWatcher` for why the watch alone is not enough.
    func scan() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: Self.directory.path) else {
            onSnapshot([])
            return
        }

        let decoder = JSONDecoder()
        var entries: [RegistryEntry] = []

        for name in names where name.hasSuffix(".json") {
            let url = Self.directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let entry = try? decoder.decode(RegistryEntry.self, from: data) else { continue }
            // A registry file can outlive its process if a session was killed hard.
            guard ProcessLiveness.isAlive(entry.pid) else { continue }
            entries.append(entry)
        }

        onSnapshot(entries)
    }
}
