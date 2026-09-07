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

    /// The store is handed the answer rather than asked to read the real preference: writing it here
    /// would change the developer's own panel, and race every other test that reads it.
    @Test("a sweep drops what it has when the numbers are off", arguments: [Provider.claude, .codex])
    func tickClearsUsage(provider: Provider) {
        let store = SessionStore(showsPlanUsage: { _ in false })
        store.usage[provider] = UsageSnapshot(
            fiveHour: UsageWindow(usedPercentage: 40, resetsAt: .now.addingTimeInterval(3600)),
            sevenDay: nil,
            updatedAt: .now
        )

        store.tick()
        #expect(store.usage[provider] == nil,
                "the panel draws whatever this holds, so hiding means emptying it")
    }

    /// A store nobody tells reads the real preference, which is what the app relies on and the only
    /// part of this the injection above could hide.
    ///
    /// Asserted in the "off" direction on purpose: "on" would have the sweep replace what is here with
    /// a fresh read of `~/.notchling/usage/`, so it would pass on a machine that has been running the
    /// status line and fail on one that has not.
    @Test("a store nobody told reads the preference itself")
    func theDefaultIsThePreference() {
        withPlanUsage(false, for: .codex) {
            let store = SessionStore()
            store.usage[.codex] = UsageSnapshot(
                fiveHour: UsageWindow(usedPercentage: 77, resetsAt: .now.addingTimeInterval(3600)),
                sevenDay: nil,
                updatedAt: .now
            )

            store.tick()
            #expect(store.usage[.codex] == nil, "the real preference reached the store")
        }
    }
}
