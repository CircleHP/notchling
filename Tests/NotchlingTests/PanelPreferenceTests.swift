import Foundation
import Testing

@testable import Notchling

/// One suite, and `.serialized`, because every test in here writes the real preference. The trait
/// orders tests within a suite and its children — it does not order two sibling suites against each
/// other — so splitting these up lets one clear the key while another is asserting on it.
///
/// Each puts back whatever was there. A developer must not come out of a test run with their own
/// panel changed.
@Suite("Plan usage preference", .serialized)
@MainActor
struct PanelPreferenceTests {
    private func withPlanUsage(_ value: Bool?, _ body: () -> Void) {
        let saved = UserDefaults.standard.object(forKey: PanelPreference.planUsageKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: PanelPreference.planUsageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PanelPreference.planUsageKey)
            }
        }
        if let value {
            PanelPreference.showsPlanUsage = value
        } else {
            UserDefaults.standard.removeObject(forKey: PanelPreference.planUsageKey)
        }
        body()
    }

    @Test("an absent key means the bars are shown, so an upgrade changes nobody's panel")
    func defaultsToOn() {
        withPlanUsage(nil) {
            #expect(PanelPreference.showsPlanUsage)
        }
    }

    @Test("both answers survive a read back")
    func roundTrips() {
        withPlanUsage(false) {
            #expect(!PanelPreference.showsPlanUsage)
            PanelPreference.showsPlanUsage = true
            #expect(PanelPreference.showsPlanUsage)
        }
    }

    @Test("a sweep drops what it has when the bars are off")
    func tickClearsUsage() {
        withPlanUsage(false) {
            let store = SessionStore()
            store.usage = UsageSnapshot(
                fiveHour: UsageWindow(usedPercentage: 40, resetsAt: .now.addingTimeInterval(3600)),
                sevenDay: nil,
                updatedAt: .now
            )

            store.tick()
            #expect(store.usage == nil, "the panel draws whatever this holds, so hiding means emptying it")
        }
    }
}
