import Foundation

/// Glue between key actions, intensity and the mixer. Thread-safe: `handle` is called from the
/// event-tap thread, configuration changes from the main thread.
public final class KeySoundCoordinator {
    public static let sensorDelay = 0.008
    public static let sensorLookBehind = 0.010

    public let mixer: VoiceMixer
    private let sampleRateProvider: () -> Double
    private let triggerQueue = DispatchQueue(label: "thock.trigger", qos: .userInteractive)
    private var lock = os_unfair_lock()
    private var settings = ThockSettings()
    private var bank: SoundBank?
    private var banks: [String: SoundBank] = [:]
    private var lastVariant: [SoundSlot: Int] = [:]
    private var lastDownTime = 0.0
    private var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000)))
    public weak var intensitySource: IntensitySource?

    public private(set) var triggeredCount = 0

    public init(mixer: VoiceMixer = VoiceMixer(), sampleRate: @escaping () -> Double = { 48_000 }) {
        self.mixer = mixer
        self.sampleRateProvider = sampleRate
    }

    private let buildQueue = DispatchQueue(label: "thock.bank-build", qos: .userInitiated)
    private var buildGeneration = 0

    /// Applies new settings. Cached sound banks switch instantly; an uncached profile is synthesised
    /// off the calling thread (about 80 ms) and swapped in when ready, so the UI never stutters.
    /// Pass `synchronous: true` to wait for the bank (used by tests and previews).
    public func apply(_ new: ThockSettings, synchronous: Bool = false) {
        let rate = sampleRateProvider()
        let profile = SoundProfiles.profile(id: new.profileID) ?? SoundProfiles.default
        os_unfair_lock_lock(&lock)
        settings = new
        let cached = banks[profile.id].flatMap { $0.sampleRate == rate ? $0 : nil }
        if let cached { bank = cached }
        buildGeneration += 1
        let generation = buildGeneration
        os_unfair_lock_unlock(&lock)
        mixer.setVolume(new.volume)
        guard cached == nil else { return }

        let build = { [weak self] in
            let built = SoundBank(profile: profile, sampleRate: rate)
            guard let self else { return }
            os_unfair_lock_lock(&self.lock)
            self.banks[profile.id] = built
            if generation == self.buildGeneration || self.settings.profileID == profile.id { self.bank = built }
            os_unfair_lock_unlock(&self.lock)
        }
        if synchronous { build() } else { buildQueue.async(execute: build) }
    }

    /// Drops cached banks (e.g. after the output sample rate changed).
    public func invalidateBanks() {
        os_unfair_lock_lock(&lock); banks.removeAll(); bank = nil; os_unfair_lock_unlock(&lock)
    }

    public var currentSettings: ThockSettings {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return settings
    }

    /// Handle a clean key action from the processor.
    public func handle(_ action: KeyAction) {
        os_unfair_lock_lock(&lock)
        let s = settings
        let b = bank
        let prevDown = lastDownTime
        if action.direction == .down { lastDownTime = action.time }
        os_unfair_lock_unlock(&lock)

        guard s.isAudible, let b else { return }
        if action.direction == .up && !s.keyReleaseSounds { return }

        if action.direction == .down, s.sensorEnabled, let src = intensitySource, src.isStreaming, action.category != .modifier {
            let t = action.time
            triggerQueue.asyncAfter(deadline: .now() + Self.sensorDelay) { [weak self] in
                guard let self else { return }
                let strength = src.strength(around: t, before: Self.sensorLookBehind, after: Self.sensorDelay)
                self.play(action, bank: b, settings: s, strength: strength ?? IntensityMapper.cadenceStrength(interval: t - prevDown))
            }
        } else {
            let strength: Double? = (action.direction == .down && s.sensorEnabled)
                ? IntensityMapper.cadenceStrength(interval: action.time - prevDown) : nil
            play(action, bank: b, settings: s, strength: strength)
        }
    }

    private func play(_ action: KeyAction, bank: SoundBank, settings s: ThockSettings, strength: Double?) {
        let variants = bank.variants(action.category, action.direction)
        guard !variants.isEmpty else { return }
        let slot = SoundSlot(category: action.category, direction: action.direction)

        os_unfair_lock_lock(&lock)
        var idx = Int(rng.next() % UInt64(variants.count))
        if variants.count > 1, idx == lastVariant[slot] { idx = (idx + 1) % variants.count }
        lastVariant[slot] = idx
        let gainJitter = 1 + 0.14 * rng.signed()          // about +-1.2 dB
        let pitchJitter = 1 + 0.025 * rng.signed()
        triggeredCount += 1
        os_unfair_lock_unlock(&lock)

        let mapped = IntensityMapper.map(strength: strength, sensitivity: s.sensitivity)
        let keyDetune = 1 + 0.012 * (KeyClassifier.horizontalPosition(forKeyCode: action.keyCode) - 0.5) * 2   // keys keep a stable identity
        let pan = Float((KeyClassifier.horizontalPosition(forKeyCode: action.keyCode) - 0.5) * 2 * s.stereoWidth)
        mixer.trigger(variants[idx], gain: Float(gainJitter) * mapped.gain, pan: pan,
                      pitch: pitchJitter * mapped.pitch * keyDetune)
    }

    /// Plays a short demonstration phrase with the given profile, independent of mute state.
    public func preview(profileID: String, volume: Double? = nil) {
        let rate = sampleRateProvider()
        let profile = SoundProfiles.profile(id: profileID) ?? SoundProfiles.default
        let b: SoundBank
        os_unfair_lock_lock(&lock)
        let cached = banks[profile.id].flatMap { $0.sampleRate == rate ? $0 : nil }
        os_unfair_lock_unlock(&lock)
        if let cached { b = cached } else {
            b = SoundBank(profile: profile, sampleRate: rate)
            os_unfair_lock_lock(&lock); banks[profile.id] = b; os_unfair_lock_unlock(&lock)
        }
        var s = currentSettings
        s.muted = false; s.enabled = true
        // t, key code, category
        let phrase: [(Double, UInt16, KeyCategory)] = [
            (0.00, 17, .alpha), (0.11, 4, .alpha), (0.20, 31, .alpha), (0.33, 8, .alpha), (0.41, 40, .alpha),
            (0.58, 49, .space), (0.78, 13, .alpha), (0.87, 34, .alpha), (0.99, 15, .alpha), (1.10, 51, .backspace),
            (1.30, 15, .alpha), (1.42, 36, .enter),
        ]
        for (t, code, cat) in phrase {
            let down = KeyAction(keyCode: code, category: cat, direction: .down, time: 0)
            let up = KeyAction(keyCode: code, category: cat, direction: .up, time: 0)
            triggerQueue.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.play(down, bank: b, settings: s, strength: 0.5)
            }
            if s.keyReleaseSounds {
                triggerQueue.asyncAfter(deadline: .now() + t + 0.07) { [weak self] in
                    self?.play(up, bank: b, settings: s, strength: 0.5)
                }
            }
        }
    }
}
