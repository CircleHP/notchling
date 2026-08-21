//
//  Whether Homebrew is what put this app here, and if so where its parts are.
//
//  Everything about updating is gated on this. An app that was built with `make install`, or copied
//  somewhere by hand, cannot be upgraded by `brew upgrade` — and offering to would be a button that
//  fails every time it is pressed.
//
//  Derived from the running bundle's own path rather than from asking `brew --prefix`, so the answer
//  is about *this* copy. A machine can have Homebrew and still be running a widget that came from
//  somewhere else.
//

import Foundation

struct HomebrewInstall: Equatable {
    /// `/opt/homebrew` on Apple silicon, `/usr/local` on Intel — but taken from the path rather than
    /// assumed, because neither is guaranteed.
    let prefix: URL

    var brew: URL { prefix.appendingPathComponent("bin/brew") }

    /// The tap is a plain git repository, which is what makes a cheap check possible: fetching it
    /// touches only remote-tracking refs, so nothing Homebrew can see changes and `brew` never runs.
    var tap: URL {
        prefix.appendingPathComponent("Library/Taps/circlehp/homebrew-notchling")
    }

    var formula: URL { tap.appendingPathComponent("Formula/notchling.rb") }

    /// Both shapes a Homebrew install can present.
    ///
    /// `opt/notchling/Notchling.app` is the version-independent symlink, which is what the service
    /// runs from and therefore the usual case. `Cellar/notchling/<version>/Notchling.app` is where
    /// that link points, and is what `Bundle.main.bundleURL` reports if the app was launched through
    /// the real path.
    static func detect(runningBundle: URL) -> HomebrewInstall? {
        let parts = runningBundle.standardizedFileURL.pathComponents
        guard parts.last == "Notchling.app" else { return nil }

        let cut: Int?
        if parts.count >= 4, parts[parts.count - 3 ... parts.count - 2] == ["opt", "notchling"] {
            cut = parts.count - 3
        } else if parts.count >= 5, parts[parts.count - 4] == "Cellar", parts[parts.count - 3] == "notchling" {
            cut = parts.count - 4
        } else {
            cut = nil
        }
        guard let cut, cut > 1 else { return nil }

        var prefix = URL(fileURLWithPath: "/")
        for component in parts[1 ..< cut] {
            prefix.appendPathComponent(component)
        }
        return HomebrewInstall(prefix: prefix)
    }

    /// The paths have to be there as well as look right. A tap the user removed, or a prefix that no
    /// longer has `brew` in it, means there is nothing to offer.
    var isUsable: Bool {
        FileManager.default.isExecutableFile(atPath: brew.path)
            && FileManager.default.fileExists(atPath: formula.path)
    }

    /// `NOTCHLING_FORCE_HOMEBREW=1` treats this copy as a Homebrew one, finding the prefix by looking
    /// for the tap in the usual places.
    ///
    /// Everything about updating is gated on the running bundle's path, and a build in `.build/` is
    /// not a path Homebrew made — so without this, none of that UI can be looked at from a development
    /// build at all. Same reason `NOTCHLING_FORCE_PILL` exists: the branch that cannot be reached on
    /// the machine you develop on is the branch that ships unlooked-at.
    private static let forced = ProcessInfo.processInfo.environment["NOTCHLING_FORCE_HOMEBREW"] == "1"

    private static let standardPrefixes = ["/opt/homebrew", "/usr/local"]

    /// The install backing this process, or nil when Homebrew is not what put it here.
    static func current(runningBundle: URL = Bundle.main.bundleURL) -> HomebrewInstall? {
        if let install = detect(runningBundle: runningBundle), install.isUsable { return install }
        guard forced else { return nil }
        return standardPrefixes
            .map { HomebrewInstall(prefix: URL(fileURLWithPath: $0)) }
            .first(where: \.isUsable)
    }
}
