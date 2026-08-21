import Foundation
import Testing

@testable import Notchling

/// The check against the real tap, over the real network.
///
/// Off unless asked for. It needs the tap checked out, which no CI runner has, and it is the only test
/// in the suite that reaches outside this machine — exactly the thing the rest of the app promises not
/// to do without being told. Run it after touching anything about how the formula is read:
///
///     NOTCHLING_LIVE_TAP=1 swift test --filter LiveTapTests
///
/// It is a real fetch of remote-tracking refs and nothing else, so it leaves the tap able to do
/// everything it could do before.
private let liveTapEnabled: Bool = {
    guard ProcessInfo.processInfo.environment["NOTCHLING_LIVE_TAP"] == "1" else { return false }
    return HomebrewInstall.current(
        runningBundle: URL(fileURLWithPath: "/opt/homebrew/opt/notchling/Notchling.app")
    ) != nil
}()

@Suite("Updates — against the real tap", .enabled(if: liveTapEnabled))
struct LiveTapTests {
    @Test("the tap answers with the version it is actually offering")
    func liveCheck() throws {
        let install = try #require(
            HomebrewInstall.current(
                runningBundle: URL(fileURLWithPath: "/opt/homebrew/opt/notchling/Notchling.app")
            )
        )

        // Pretending to be ahead of every release: there is nothing to offer.
        #expect(try Updates.available(in: install, installedVersion: "99.0.0") == nil)

        // Pretending to be behind every release: whatever the tap currently has.
        let offered = try #require(try Updates.available(in: install, installedVersion: "0.0.1"))
        #expect(Updates.version(inFormula: try String(contentsOf: install.formula, encoding: .utf8)) != nil)
        print("live tap offers \(offered)")
    }
}
