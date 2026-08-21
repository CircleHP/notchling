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

    /// `NOTCHLING_FORCE_HOMEBREW=/opt/homebrew` treats this copy as one installed from that prefix.
    ///
    /// Everything about updating is gated on the running bundle's path, and a build in `.build/` is
    /// not a path Homebrew made — so without this, none of that UI can be looked at from a development
    /// build at all. Same reason `NOTCHLING_FORCE_PILL` exists: the branch that cannot be reached on
    /// the machine you develop on is the branch that ships unlooked-at.
    ///
    /// The prefix comes from the variable rather than from a list of the usual ones in here, and that
    /// is not a stylistic choice. Homebrew decides whether a bottle can be poured into any prefix by
    /// looking for its own prefix *inside the installed files*, so a literal `/opt/homebrew` anywhere
    /// in this binary makes every bottle non-relocatable — and the tap's release step refuses to
    /// publish one, which is exactly how the first attempt at 1.2.0 was caught. `PrefixLiteralTests`
    /// keeps it that way.
    private static var forcedPrefix: URL? {
        guard let raw = ProcessInfo.processInfo.environment["NOTCHLING_FORCE_HOMEBREW"], !raw.isEmpty
        else { return nil }
        return URL(fileURLWithPath: raw)
    }

    /// The install backing this process, or nil when Homebrew is not what put it here.
    static func current(runningBundle: URL = Bundle.main.bundleURL) -> HomebrewInstall? {
        if let install = detect(runningBundle: runningBundle), install.isUsable { return install }
        guard let forcedPrefix else { return nil }
        let forced = HomebrewInstall(prefix: forcedPrefix)
        return forced.isUsable ? forced : nil
    }
}
