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

    /// Registry files that did not decode last scan, so each one is reported once rather than every
    /// two seconds. See `scan()`.
    private var unreadable: Set<String> = []
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

        // Logged once per file rather than on every scan: this runs every two seconds, and a
        // registry whose shape has changed would otherwise repeat the same line all day. A file that
        // starts decoding again drops out of the set and can report itself afresh.
        var stillUnreadable: Set<String> = []

        for name in names where name.hasSuffix(".json") {
            let url = Self.directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let entry = try? decoder.decode(RegistryEntry.self, from: data) else {
                stillUnreadable.insert(name)
                if !unreadable.contains(name) {
                    Log.registry.error(
                        """
                        \(name, privacy: .public) does not decode as a session entry — the registry \
                        format may have changed, and sessions it describes will not appear
                        """
                    )
                }
                continue
            }
            // A registry file can outlive its process if a session was killed hard.
            guard ProcessLiveness.isAlive(entry.pid) else { continue }
            entries.append(entry)
        }

        unreadable = stillUnreadable
        onSnapshot(entries)
    }
}
