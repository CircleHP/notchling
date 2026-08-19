import Foundation
import Testing

@testable import Notchling

@Suite("InstalledBuild")
struct InstalledBuildTests {
    private func makeBundle(version: String?, in directory: URL, named name: String = "Notchling.app") -> URL {
        let bundle = directory.appendingPathComponent(name)
        let contents = bundle.appendingPathComponent("Contents")
        try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let version {
            let plist = ["CFBundleShortVersionString": version]
            let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try! data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        return bundle
    }

    @Test("a Cellar path resolves to the opt path, which is the only one an upgrade moves")
    func cellarResolvesToOpt() {
        let running = URL(fileURLWithPath: "/opt/homebrew/Cellar/notchling/1.0.3/Notchling.app")
        #expect(
            InstalledBuild.installedBundle(forRunningBundleAt: running).path
                == "/opt/homebrew/opt/notchling/Notchling.app"
        )
    }

    @Test("an Intel prefix resolves too, because the prefix is read from the path rather than assumed")
    func intelPrefix() {
        let running = URL(fileURLWithPath: "/usr/local/Cellar/notchling/2.0.0/Notchling.app")
        #expect(
            InstalledBuild.installedBundle(forRunningBundleAt: running).path
                == "/usr/local/opt/notchling/Notchling.app"
        )
    }

    @Test("anywhere else compares against itself, because that is where the replacement lands")
    func nonBrewComparesAgainstItself() {
        let running = URL(fileURLWithPath: "/Users/someone/Applications/Notchling.app")
        #expect(InstalledBuild.installedBundle(forRunningBundleAt: running) == running)
    }

    @Test("the version comes off disk, not out of the running process")
    func readsVersionFromDisk() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = makeBundle(version: "1.2.3", in: directory)
        #expect(InstalledBuild.version(ofBundleAt: bundle) == "1.2.3")
    }

    @Test("a bundle with no readable version reports nothing rather than guessing")
    func missingVersion() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(InstalledBuild.version(ofBundleAt: makeBundle(version: nil, in: directory)) == nil)
        #expect(InstalledBuild.version(ofBundleAt: directory.appendingPathComponent("Nothing.app")) == nil)
    }

    @Test("a version on disk that differs from the running one is what gets reported")
    func reportsADifference() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = makeBundle(version: "1.0.4", in: directory)
        #expect(InstalledBuild.pendingVersion(runningVersion: "1.0.3", runningBundle: bundle) == "1.0.4")
    }

    @Test("a downgrade counts as well, since it is equally a build the user is not running")
    func reportsADowngrade() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = makeBundle(version: "1.0.2", in: directory)
        #expect(InstalledBuild.pendingVersion(runningVersion: "1.0.3", runningBundle: bundle) == "1.0.2")
    }

    @Test("matching versions, and an unreadable bundle, report nothing")
    func quietWhenThereIsNothingToSay() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let same = makeBundle(version: "1.0.3", in: directory)
        #expect(InstalledBuild.pendingVersion(runningVersion: "1.0.3", runningBundle: same) == nil)

        let missing = directory.appendingPathComponent("Gone.app")
        #expect(InstalledBuild.pendingVersion(runningVersion: "1.0.3", runningBundle: missing) == nil)
        #expect(InstalledBuild.pendingVersion(runningVersion: nil, runningBundle: same) == nil)
    }
}
