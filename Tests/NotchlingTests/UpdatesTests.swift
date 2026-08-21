import Foundation
import Testing

@testable import Notchling

@Suite("HomebrewInstall")
struct HomebrewInstallTests {
    /// The usual case: the service runs the version-independent symlink, so this is what
    /// `Bundle.main.bundleURL` reports on nearly every machine.
    @Test("the opt symlink gives up the prefix")
    func optPath() {
        let install = HomebrewInstall.detect(
            runningBundle: URL(fileURLWithPath: "/opt/homebrew/opt/notchling/Notchling.app")
        )
        #expect(install?.prefix.path == "/opt/homebrew")
        #expect(install?.brew.path == "/opt/homebrew/bin/brew")
        #expect(install?.tap.path == "/opt/homebrew/Library/Taps/circlehp/homebrew-notchling")
    }

    @Test("so does the Cellar path the symlink points at")
    func cellarPath() {
        let install = HomebrewInstall.detect(
            runningBundle: URL(fileURLWithPath: "/opt/homebrew/Cellar/notchling/1.1.2/Notchling.app")
        )
        #expect(install?.prefix.path == "/opt/homebrew")
    }

    /// Intel machines, and anyone who put their prefix somewhere else. Taken from the path rather than
    /// assumed, which is the whole reason this is not a constant.
    @Test("the prefix is read, not assumed")
    func otherPrefixes() {
        #expect(
            HomebrewInstall.detect(
                runningBundle: URL(fileURLWithPath: "/usr/local/opt/notchling/Notchling.app")
            )?.prefix.path == "/usr/local"
        )
        #expect(
            HomebrewInstall.detect(
                runningBundle: URL(fileURLWithPath: "/Users/me/brew/Cellar/notchling/2.0.0/Notchling.app")
            )?.prefix.path == "/Users/me/brew"
        )
    }

    /// The gate on the whole feature. Offering `brew upgrade` to a copy Homebrew did not install is a
    /// button that fails every single time it is pressed.
    @Test("anywhere Homebrew did not put it is not a Homebrew install", arguments: [
        "/Users/me/Applications/Notchling.app",
        "/Applications/Notchling.app",
        "/Users/me/src/notchling/.build/bundle/Notchling.app",
        "/opt/homebrew/opt/somethingelse/Notchling.app",
        "/opt/homebrew/Cellar/somethingelse/1.0.0/Notchling.app",
    ])
    func rejectsNonHomebrewPaths(path: String) {
        #expect(HomebrewInstall.detect(runningBundle: URL(fileURLWithPath: path)) == nil)
    }

    @Test("a path that is not a bundle at all is not one either")
    func rejectsNonBundle() {
        #expect(HomebrewInstall.detect(runningBundle: URL(fileURLWithPath: "/opt/homebrew/opt/notchling")) == nil)
    }
}

@Suite("Updates")
struct UpdatesTests {
    /// Trimmed from the real tap.
    private let formula = """
    class Notchling < Formula
      desc "Notch widget showing live status for every Claude Code session"
      homepage "https://github.com/CircleHP/notchling"
      url "https://github.com/CircleHP/notchling/releases/download/v1.1.2/notchling-1.1.2-universal.tar.gz"
      sha256 "e38d6b0ad67b7e711df18101fbed0f560b19e785b48c639812520168e05051c7"
      license "MIT"
    end
    """

    @Test("the version comes out of the release URL, which is where Homebrew gets it too")
    func readsTheVersion() {
        #expect(Updates.version(inFormula: formula) == "1.1.2")
    }

    /// A check that cannot read the formula has to go quiet. Prompting with a guessed version is worse
    /// than not prompting: `brew upgrade` would not satisfy it, and it would come back tomorrow.
    @Test("a formula it cannot read yields nothing rather than a guess")
    func unreadableFormula() {
        #expect(Updates.version(inFormula: "") == nil)
        #expect(Updates.version(inFormula: "url \"https://example.com/notchling.tar.gz\"") == nil)
        #expect(Updates.version(inFormula: "# releases/download/vNEXT/notchling.tar.gz") == nil)
    }

    @Test("versions order by number, not by string")
    func ordering() {
        #expect(Updates.isNewer("1.1.3", than: "1.1.2"))
        #expect(Updates.isNewer("1.2.0", than: "1.1.9"))
        // The one a string comparison gets wrong.
        #expect(Updates.isNewer("1.10.0", than: "1.9.0"))
        #expect(Updates.isNewer("2.0.0", than: "1.99.99"))
    }

    /// Never offer to go backwards. Somebody running a build they made themselves is ahead of the tap,
    /// and "install 1.1.2" over their 1.2.0 would be a downgrade dressed up as an update.
    @Test("the same version, or an older one, is not an update")
    func neverOffersADowngrade() {
        #expect(!Updates.isNewer("1.1.2", than: "1.1.2"))
        #expect(!Updates.isNewer("1.1.1", than: "1.1.2"))
        #expect(!Updates.isNewer("1.0.0", than: "2.0.0"))
    }

    /// The two that keep one click meaning one formula. Verified live before this existed: a bare
    /// `brew outdated notchling` auto-updated Homebrew and refreshed homebrew/core, which would then
    /// make the user's next plain `brew upgrade` upgrade everything on the machine.
    @Test("brew is run with auto-update and cleanup off")
    func brewEnvironmentIsConstrained() {
        #expect(Updates.brewEnvironment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(Updates.brewEnvironment["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
    }
}

@Suite("UpdatePreference")
struct UpdatePreferenceTests {
    private func at(_ hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 21
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    /// The state every existing install upgrades into, and the one that keeps the privacy claim true:
    /// until somebody answers, nothing reaches the network.
    @Test("an unanswered question is never a yes")
    func unsetNeverChecks() {
        #expect(!UpdatePreference.isDue(now: at(12), lastCheckedDay: nil, choice: .unset, hour: 11))
        #expect(!UpdatePreference.isDue(now: at(12), lastCheckedDay: nil, choice: .off, hour: 11))
    }

    @Test("nothing happens before the hour, once a check is on record")
    func waitsForTheHour() {
        #expect(!UpdatePreference.isDue(now: at(10), lastCheckedDay: "2026-08-20", choice: .on, hour: 11))
        #expect(UpdatePreference.isDue(now: at(11), lastCheckedDay: "2026-08-20", choice: .on, hour: 11))
        #expect(UpdatePreference.isDue(now: at(23), lastCheckedDay: "2026-08-20", choice: .on, hour: 11))
    }

    /// The hole the hour picker opened. Requiring both "the hour has passed" and "a different day"
    /// means a machine that is never awake at the chosen hour never satisfies both — set it to 7pm on
    /// a laptop that shuts at 6 and the feature silently does nothing at all, for ever.
    @Test("an hour the machine is never awake for still checks eventually")
    func aMissedDayOverridesTheHour() {
        // One day since the last check: the hour still governs, so this waits.
        #expect(!UpdatePreference.isDue(now: at(10), lastCheckedDay: "2026-08-20", choice: .on, hour: 19))
        // Two days: the hour is evidently unreachable, so go anyway.
        #expect(UpdatePreference.isDue(now: at(10), lastCheckedDay: "2026-08-19", choice: .on, hour: 19))
        // Turning it on and never having checked is due at once, so the answer visibly does something.
        #expect(UpdatePreference.isDue(now: at(10), lastCheckedDay: nil, choice: .on, hour: 19))
    }

    /// A machine asleep at 11:00 checks on the first sweep after it wakes — which is why this is a
    /// calendar day rather than an interval since the last one.
    @Test("once a day, whenever the machine was actually awake")
    func onceADay() {
        let today = UpdatePreference.day(of: at(12))
        #expect(!UpdatePreference.isDue(now: at(12), lastCheckedDay: today, choice: .on, hour: 11))
        #expect(!UpdatePreference.isDue(now: at(23), lastCheckedDay: today, choice: .on, hour: 11),
                "still the same day, however late it got")
        #expect(UpdatePreference.isDue(now: at(12), lastCheckedDay: "2026-08-20", choice: .on, hour: 11))
        #expect(UpdatePreference.isDue(now: at(12), lastCheckedDay: nil, choice: .on, hour: 11),
                "never checked is due")
        #expect(!UpdatePreference.isDue(now: at(12), lastCheckedDay: today, choice: .off, hour: 11),
                "off still means off, however stale")
    }

    /// A plain `defaults` key, so it can hold anything. An hour of 47 would make a check that is never
    /// due — a feature that silently does nothing, which is the worst way for a setting to be wrong.
    @Test("an hour out of range is clamped rather than believed")
    func hourIsClamped() {
        let key = UpdatePreference.hourKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        UserDefaults.standard.set(47, forKey: key)
        #expect(UpdatePreference.hour == 23)
        UserDefaults.standard.set(-3, forKey: key)
        #expect(UpdatePreference.hour == 0)
        UserDefaults.standard.removeObject(forKey: key)
        #expect(UpdatePreference.hour == UpdatePreference.defaultHour)
        #expect(UpdatePreference.defaultHour == 11)
    }

    @Test("hours read as times of day")
    func hourLabels() {
        #expect(UpdatePreference.label(forHour: 0) == "12am")
        #expect(UpdatePreference.label(forHour: 9) == "9am")
        #expect(UpdatePreference.label(forHour: 11) == "11am")
        #expect(UpdatePreference.label(forHour: 12) == "12pm")
        #expect(UpdatePreference.label(forHour: 15) == "3pm")
        #expect(UpdatePreference.label(forHour: 23) == "11pm")
    }

    @Test("the day key sorts and is locale-independent")
    func dayFormat() {
        #expect(UpdatePreference.day(of: Date(timeIntervalSince1970: 0)).count == 10)
        #expect(UpdatePreference.day(of: at(12)) == "2026-08-21")
    }
}

@Suite("Homebrew prefix literals")
struct PrefixLiteralTests {
    /// A source-level check, because it is the only kind that works.
    ///
    /// Homebrew decides whether a bottle can be poured into any prefix by searching the installed
    /// files for its own prefix. One `"/opt/homebrew"` in this binary makes every bottle
    /// non-relocatable, so the tap's release step refuses to publish it — the first attempt at 1.2.0
    /// failed exactly there, after the app release had already been tagged.
    ///
    /// Nothing about that is visible in a build, a test run, or the app itself. It only shows up in a
    /// release that is already half done.
    @Test("no source names a Homebrew prefix")
    func noPrefixLiterals() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty, "found no sources to check")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                // Comments may name a prefix — explaining this rule requires it. Only code counts.
                let code = text.range(of: "//").map { String(text[text.startIndex ..< $0.lowerBound]) } ?? text
                for prefix in ["/opt/homebrew", "/usr/local"] where code.contains(prefix) {
                    Issue.record("\(file.lastPathComponent):\(number + 1) names \(prefix) — take it from the environment or the running bundle's path instead")
                }
            }
        }
    }
}
