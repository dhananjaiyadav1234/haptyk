import Testing
import Foundation
@testable import ThockCore

@Suite("Settings persistence")
struct SettingsTests {
    func freshDefaults() -> UserDefaults {
        let name = "thock.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsWhenNothingStored() {
        let s = SettingsStore(defaults: freshDefaults()).load()
        #expect(s == ThockSettings())
        #expect(s.enabled && !s.muted)
    }

    @Test func roundTripAcrossStoreInstances() {
        let d = freshDefaults()
        var s = ThockSettings()
        s.volume = 0.31; s.muted = true; s.profileID = "topre"; s.sensitivity = 0.9
        s.keyReleaseSounds = false; s.sensorEnabled = false; s.enabled = false; s.stereoWidth = 0.1
        SettingsStore(defaults: d).save(s)
        // "restart": a brand new store reading the same defaults
        let loaded = SettingsStore(defaults: d).load()
        #expect(loaded == s)
    }

    @Test func corruptDataFallsBackToDefaults() {
        let d = freshDefaults()
        d.set(Data("not json".utf8), forKey: SettingsStore.key)
        #expect(SettingsStore(defaults: d).load() == ThockSettings())
    }

    @Test func outOfRangeAndUnknownValuesAreSanitised() throws {
        let json = #"{"volume": 7.5, "sensitivity": -3, "profileID": "does-not-exist", "muted": true}"#
        let s = try JSONDecoder().decode(ThockSettings.self, from: Data(json.utf8))
        #expect(s.volume == 1 && s.sensitivity == 0)
        #expect(s.profileID == ThockSettings().profileID)
        #expect(s.muted)
    }

    @Test func audibleOnlyWhenEnabledAndNotMuted() {
        var s = ThockSettings()
        #expect(s.isAudible)
        s.muted = true; #expect(!s.isAudible)
        s.muted = false; s.enabled = false; #expect(!s.isAudible)
    }
}
