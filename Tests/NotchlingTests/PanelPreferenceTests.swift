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
    private func withPlanUsage(
        _ value: Bool?,
        for provider: Provider = .claude,
        _ body: () -> Void
    ) {
        let key = PanelPreference.key(for: provider)
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let value {
            PanelPreference.setShowsPlanUsage(value, for: provider)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        body()
    }

    @Test("an absent key means the numbers are shown, so an upgrade changes nobody's panel")
    func defaultsToOn() {
        for provider in [Provider.claude, .codex] {
            withPlanUsage(nil, for: provider) {
                #expect(PanelPreference.showsPlanUsage(for: provider))
            }
        }
    }

    @Test("both answers survive a read back")
    func roundTrips() {
        withPlanUsage(false) {
            #expect(!PanelPreference.showsPlanUsage(for: .claude))
            PanelPreference.setShowsPlanUsage(true, for: .claude)
            #expect(PanelPreference.showsPlanUsage(for: .claude))
        }
    }

    /// Claude's key keeps the name it always had, so an upgrade does not hand the numbers back to
    /// somebody who turned them off.
    @Test("the existing preference is still the one Claude reads")
    func claudeKeepsItsKey() {
        #expect(PanelPreference.key(for: .claude) == "showPlanUsage")
        #expect(PanelPreference.key(for: .codex) != PanelPreference.key(for: .claude))
    }

    /// Separate accounts on separate plans: turning one off must not take the other with it.
    @Test("one agent's switch says nothing about the other's")
    func switchesAreIndependent() {
        withPlanUsage(false, for: .claude) {
            withPlanUsage(true, for: .codex) {
                #expect(!PanelPreference.showsPlanUsage(for: .claude))
                #expect(PanelPreference.showsPlanUsage(for: .codex))
            }
        }
    }

    @Test("a sweep drops what it has when the numbers are off")
    func tickClearsUsage() {
        withPlanUsage(false) {
            let store = SessionStore()
            store.usage[.claude] = UsageSnapshot(
                fiveHour: UsageWindow(usedPercentage: 40, resetsAt: .now.addingTimeInterval(3600)),
                sevenDay: nil,
                updatedAt: .now
            )

            store.tick()
            #expect(store.usage[.claude] == nil,
                    "the panel draws whatever this holds, so hiding means emptying it")
        }
    }

    /// Turning Codex's off must clear what its rollouts already reported, not merely stop reading more.
    @Test("a sweep drops the other agent's too")
    func tickClearsCodexUsage() {
        withPlanUsage(false, for: .codex) {
            let store = SessionStore()
            store.usage[.codex] = UsageSnapshot(
                fiveHour: UsageWindow(usedPercentage: 77, resetsAt: .now.addingTimeInterval(3600)),
                sevenDay: nil,
                updatedAt: .now
            )

            store.tick()
            #expect(store.usage[.codex] == nil)
        }
    }
}
