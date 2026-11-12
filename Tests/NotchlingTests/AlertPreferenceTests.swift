import Foundation
import Testing

@testable import Notchling

/// Each test gets its own defaults domain, so nothing here reads or changes the developer's own alerts.
@Suite("Alert preference")
struct AlertPreferenceTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "notchling.tests.alerts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test("an absent key alerts on everything, so an upgrade changes nobody's alerts")
    func defaultsToOn() {
        withDefaults { defaults in
            #expect(AlertPreference.isEnabled(in: defaults))
            for event in AlertEvent.allCases {
                for channel in AlertChannel.allCases {
                    #expect(AlertPreference.allows(event, on: channel, in: defaults))
                }
            }
        }
    }

    @Test("the master switch silences every cell on both channels")
    func masterSwitchWins() {
        withDefaults { defaults in
            AlertPreference.setEnabled(false, in: defaults)
            for event in AlertEvent.allCases {
                for channel in AlertChannel.allCases {
                    #expect(!AlertPreference.allows(event, on: channel, in: defaults))
                }
            }
        }
    }

    /// The grid keeps its answers under the master switch, so turning alerts back on restores them.
    @Test("turning the master switch back on restores the grid")
    func masterSwitchKeepsTheGrid() {
        withDefaults { defaults in
            AlertPreference.setChecked(false, .done, on: .popUp, in: defaults)
            AlertPreference.setEnabled(false, in: defaults)
            AlertPreference.setEnabled(true, in: defaults)

            #expect(!AlertPreference.allows(.done, on: .popUp, in: defaults))
            #expect(AlertPreference.allows(.needsYou, on: .popUp, in: defaults))
        }
    }

    @Test("a cell says nothing about its neighbours")
    func cellsAreIndependent() {
        withDefaults { defaults in
            AlertPreference.setChecked(false, .done, on: .sound, in: defaults)

            #expect(!AlertPreference.allows(.done, on: .sound, in: defaults))
            #expect(AlertPreference.allows(.done, on: .popUp, in: defaults), "same event, other channel")
            #expect(AlertPreference.allows(.error, on: .sound, in: defaults), "same channel, other event")
        }
    }

    @Test("every notifiable state is an alert event, and nothing else is")
    func eventsMatchNotifiableStates() {
        for state in [SessionState.needsYou, .done, .error, .working, .idle] {
            #expect((AlertEvent(state: state) != nil) == state.isNotifiable)
        }
    }
}
