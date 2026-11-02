import Foundation
import Combine

public struct ThockSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var muted = false
    public var volume = 0.7
    public var profileID = "mx-blue"
    public var keyReleaseSounds = true
    public var sensorEnabled = true
    public var sensitivity = 0.6
    public var stereoWidth = 0.35

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, muted, volume, profileID, keyReleaseSounds, sensorEnabled, sensitivity, stereoWidth
    }

    /// Tolerant decoding: missing or out-of-range values fall back to defaults so an
    /// older or damaged settings blob never prevents launch.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ThockSettings()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        muted = (try? c.decode(Bool.self, forKey: .muted)) ?? d.muted
        volume = ThockSettings.clamp((try? c.decode(Double.self, forKey: .volume)) ?? d.volume)
        profileID = (try? c.decode(String.self, forKey: .profileID)) ?? d.profileID
        if SoundProfiles.profile(id: profileID) == nil { profileID = d.profileID }
        keyReleaseSounds = (try? c.decode(Bool.self, forKey: .keyReleaseSounds)) ?? d.keyReleaseSounds
        sensorEnabled = (try? c.decode(Bool.self, forKey: .sensorEnabled)) ?? d.sensorEnabled
        sensitivity = ThockSettings.clamp((try? c.decode(Double.self, forKey: .sensitivity)) ?? d.sensitivity)
        stereoWidth = ThockSettings.clamp((try? c.decode(Double.self, forKey: .stereoWidth)) ?? d.stereoWidth)
    }

    static func clamp(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }

    /// Sound is produced only when the app is on and not muted.
    public var isAudible: Bool { enabled && !muted }
}

public final class SettingsStore {
    public static let key = "thock.settings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> ThockSettings {
        guard let data = defaults.data(forKey: Self.key),
              let s = try? JSONDecoder().decode(ThockSettings.self, from: data) else { return ThockSettings() }
        return s
    }

    public func save(_ s: ThockSettings) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.key) }
    }
}
