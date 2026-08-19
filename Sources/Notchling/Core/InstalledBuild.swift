//
//  Which build is on disk, as opposed to which one this process is running.
//
//  Replacing an app's files does not touch the process already executing them, so an upgrade takes
//  effect only when the widget is restarted. Nothing else notices: the package manager reports the
//  new version, the `opt` path resolves to it, and only the running process disagrees.
//

import Foundation

enum InstalledBuild {
    /// Read once at launch, from the copy this process actually started from.
    static var running: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Where the current install lives, which is not always where this process is running from.
    ///
    /// Homebrew installs into `<prefix>/Cellar/notchling/<version>/Notchling.app` and points
    /// `<prefix>/opt/notchling` at whichever of those is current. An upgrade adds a new Cellar
    /// directory and moves that link, leaving this process running out of a directory that still
    /// exists and still carries the old version — so the running path can never report an upgrade.
    /// The `opt` path is the one that moves.
    ///
    /// Anywhere else, including `make install`, the bundle is replaced where it stands, and the path
    /// this process launched from is the path to compare against.
    static func installedBundle(forRunningBundleAt url: URL) -> URL {
        let parts = url.pathComponents
        guard let cellar = parts.firstIndex(of: "Cellar"), cellar > 1 else { return url }

        var prefix = URL(fileURLWithPath: "/")
        for component in parts[1 ..< cellar] {
            prefix.appendPathComponent(component)
        }
        return prefix
            .appendingPathComponent("opt")
            .appendingPathComponent("notchling")
            .appendingPathComponent("Notchling.app")
    }

    /// Read from the file rather than from `Bundle`, which caches per path for the life of the
    /// process — the whole point here is to see a value that changed after launch.
    static func version(ofBundleAt url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents").appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let contents = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let fields = contents as? [String: Any]
        else { return nil }
        return fields["CFBundleShortVersionString"] as? String
    }

    /// The version waiting on disk, or nil when it is the one already running — and when there is
    /// nothing to compare against, which is every case where the app was moved somewhere unexpected.
    ///
    /// Deliberately "different" rather than "newer": a downgrade is just as much a build the user
    /// installed and is not getting, and comparing version strings by hand invents an ordering the
    /// project does not otherwise have.
    static func pendingVersion(
        runningVersion: String? = InstalledBuild.running,
        runningBundle: URL = Bundle.main.bundleURL
    ) -> String? {
        guard let runningVersion else { return nil }
        guard let installed = version(ofBundleAt: installedBundle(forRunningBundleAt: runningBundle)) else {
            return nil
        }
        return installed == runningVersion ? nil : installed
    }
}
