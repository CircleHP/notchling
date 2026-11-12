import AppKit
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

    @Test("with nothing chosen, each event plays the sound it always has")
    func defaultSounds() {
        withDefaults { defaults in
            let names = AlertEvent.allCases.map { AlertPreference.soundName(for: $0, in: defaults) }
            #expect(names == ["Submarine", "Basso", "Tink", "Glass"])
            let loaded = AlertEvent.allCases.map { AlertPreference.sound(for: $0, in: defaults)?.name }
            #expect(loaded == ["Submarine", "Basso", "Tink", "Glass"])
        }
    }

    @Test("a chosen sound is the one played, and the one the settings name")
    func chosenSound() {
        withDefaults { defaults in
            AlertPreference.setSound("Hero", for: .done, in: defaults)
            #expect(AlertPreference.sound(for: .done, in: defaults)?.name == "Hero")
            #expect(AlertPreference.soundName(for: .done, in: defaults) == "Hero")
            #expect(AlertPreference.soundName(for: .error, in: defaults) == "Basso", "other events keep theirs")
        }
    }

    /// A custom sound removed from `~/Library/Sounds` must not turn an alert silent, and the settings
    /// must name what actually plays.
    @Test("a chosen sound that no longer loads falls back to the default")
    func missingSoundFallsBack() {
        withDefaults { defaults in
            AlertPreference.setSound("Notchling Test Sound That Does Not Exist", for: .needsYou, in: defaults)
            #expect(AlertPreference.sound(for: .needsYou, in: defaults)?.name == "Submarine")
            #expect(AlertPreference.soundName(for: .needsYou, in: defaults) == "Submarine")
        }
    }

    @Test("a chosen sound is loaded once per alert")
    func loadsOnce() {
        withDefaults { defaults in
            AlertPreference.setSound("Hero", for: .done, in: defaults)
            var loads: [String] = []
            _ = AlertPreference.sound(for: .done, in: defaults) { loads.append($0); return NSSound(named: $0) }
            #expect(loads == ["Hero"])
        }
    }
}

@Suite("Sound library")
struct SoundLibraryTests {
    @Test("lists audio files by name, once each, sorted, and skips everything else")
    func listsNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchling-sounds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let system = root.appendingPathComponent("system")
        let user = root.appendingPathComponent("user")
        for directory in [system, user] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for file in ["Tink.aiff", "Basso.aiff", "README.txt"] {
            FileManager.default.createFile(atPath: system.appendingPathComponent(file).path, contents: Data())
        }
        for file in ["Tink.wav", "chime.WAV"] {
            FileManager.default.createFile(atPath: user.appendingPathComponent(file).path, contents: Data())
        }

        let missing = root.appendingPathComponent("absent")
        #expect(SoundLibrary.names(in: [system, user, missing]) == ["Basso", "chime", "Tink"])
    }

    @Test("the system sounds are found on this machine")
    func findsSystemSounds() {
        #expect(SoundLibrary.names().contains("Submarine"))
    }

    @Test("only names that load are offered")
    func offersOnlyPlayable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchling-sounds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in ["Good.aiff", "Broken.m4a"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(file).path, contents: Data())
        }

        #expect(SoundLibrary.playableNames(in: [root], isAvailable: { $0 == "Good" }) == ["Good"])
    }
}
