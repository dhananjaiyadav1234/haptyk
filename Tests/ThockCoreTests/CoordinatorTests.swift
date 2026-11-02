import Testing
import Foundation
@testable import ThockCore

final class FakeSensor: IntensitySource {
    var isStreaming = true
    var value: Double? = 0.9
    func strength(around time: Double, before: Double, after: Double) -> Double? { value }
}

@Suite("Coordinator and intensity")
struct CoordinatorTests {
    func make(_ configure: (inout ThockSettings) -> Void = { _ in }) -> (KeySoundCoordinator, VoiceMixer) {
        let mixer = VoiceMixer()
        let c = KeySoundCoordinator(mixer: mixer, sampleRate: { rate })
        var s = ThockSettings()
        s.sensorEnabled = false
        configure(&s)
        c.apply(s, synchronous: true)
        return (c, mixer)
    }

    func down(_ code: UInt16 = 0, _ cat: KeyCategory = .alpha, t: Double = 1) -> KeyAction {
        KeyAction(keyCode: code, category: cat, direction: .down, time: t)
    }
    func up(_ code: UInt16 = 0, _ cat: KeyCategory = .alpha) -> KeyAction {
        KeyAction(keyCode: code, category: cat, direction: .up, time: 1.1)
    }
    func rendered(_ m: VoiceMixer) -> Float {
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 512), r = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { l.deallocate(); r.deallocate() }
        m.render(frames: 512, left: l, right: r)
        return (0..<512).map { max(abs(l[$0]), abs(r[$0])) }.max() ?? 0
    }

    @Test func keyDownProducesSound() {
        let (c, m) = make()
        c.handle(down())
        #expect(rendered(m) > 0.05)
    }

    @Test func mutedAndDisabledProduceNothing() {
        let (c1, m1) = make { $0.muted = true }
        c1.handle(down()); #expect(rendered(m1) == 0)
        let (c2, m2) = make { $0.enabled = false }
        c2.handle(down()); #expect(rendered(m2) == 0)
    }

    @Test func keyReleaseSoundsCanBeDisabled() {
        let (c1, m1) = make { $0.keyReleaseSounds = false }
        c1.handle(up()); #expect(rendered(m1) == 0)
        let (c2, m2) = make { $0.keyReleaseSounds = true }
        c2.handle(up()); #expect(rendered(m2) > 0.02)
    }

    @Test func profileSwitchingChangesTheSoundActuallyPlayed() {
        func firstBlock(_ id: String) -> [Float] {
            let (c, m) = make { $0.profileID = id }
            c.handle(down(0, .alpha))
            let l = UnsafeMutablePointer<Float>.allocate(capacity: 1024), r = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
            defer { l.deallocate(); r.deallocate() }
            m.render(frames: 1024, left: l, right: r)
            return Array(UnsafeBufferPointer(start: l, count: 1024))
        }
        let blue = firstBlock("mx-blue"), topre = firstBlock("topre")
        #expect(blue != topre)
        // Switching at runtime on one coordinator
        let (c, m) = make { $0.profileID = "mx-blue" }
        var s = c.currentSettings
        s.profileID = "topre"
        c.apply(s, synchronous: true)
        #expect(c.currentSettings.profileID == "topre")
        c.handle(down()); #expect(rendered(m) > 0.05)
    }

    @Test func volumeSettingReachesMixer() {
        let (c1, m1) = make { $0.volume = 1.0 }
        let (c2, m2) = make { $0.volume = 0.3 }
        // same seed not guaranteed, so compare with generous margin
        for _ in 0..<5 { c1.handle(down()); c2.handle(down()) }
        #expect(rendered(m1) > rendered(m2) * 2)
    }

    @Test func rapidTypingKeepsEverySound() {
        let (c, m) = make()
        for i in 0..<30 { c.handle(down(UInt16(i % 40), .alpha, t: Double(i) * 0.03)) }
        #expect(c.triggeredCount == 30)
        #expect(m.activeVoiceCount >= 30 || m.activeVoiceCount == VoiceMixer.maxVoices)
    }

    @Test func sensorStrengthControlsLoudness() async throws {
        func loudness(strength: Double, sensitivity: Double) async -> Float {
            let sensor = FakeSensor(); sensor.value = strength
            let mixer = VoiceMixer()
            let c = KeySoundCoordinator(mixer: mixer, sampleRate: { rate })
            var s = ThockSettings(); s.sensorEnabled = true; s.sensitivity = sensitivity
            c.apply(s, synchronous: true)
            c.intensitySource = sensor
            // average over several presses to wash out the +-1.2 dB random jitter
            var sum: Float = 0
            for k in 0..<6 {
                c.handle(down(UInt16(k), .alpha, t: ProcessClock.now()))
                try? await Task.sleep(nanoseconds: 40_000_000)
                sum += rendered(mixer)
            }
            return sum / 6
        }
        let hard = await loudness(strength: 1.0, sensitivity: 1.0)
        let soft = await loudness(strength: 0.05, sensitivity: 1.0)
        #expect(hard > soft * 1.8, "hard \(hard) vs soft \(soft)")
        let flatHard = await loudness(strength: 1.0, sensitivity: 0)
        let flatSoft = await loudness(strength: 0.05, sensitivity: 0)
        #expect(abs(flatHard - flatSoft) / max(flatHard, flatSoft) < 0.25, "zero sensitivity should flatten dynamics")
    }
}

@Suite("Accelerometer analysis")
struct IntensityTests {
    /// Feeds 800 Hz gravity + noise, with an optional decaying 120 Hz impact at `impactAt`.
    func feed(_ a: AccelerometerAnalyzer, from t0: Double, seconds: Double, impactAt: Double? = nil, amplitude: Float = 0, seed: UInt64 = 5) {
        var rng = SplitMix64(seed: seed)
        let n = Int(seconds * 800)
        for i in 0..<n {
            let t = t0 + Double(i) / 800
            var z: Float = -1 + 0.0015 * Float(rng.signed())
            if let hit = impactAt, t >= hit { z += amplitude * Float(exp(-(t - hit) / 0.01) * sin(2 * .pi * 120 * (t - hit))) }
            a.ingest(x: 0.0015 * Float(rng.signed()), y: 0.0015 * Float(rng.signed()), z: z, at: t)
        }
    }

    @Test func detectsImpactAboveNoiseFloor() {
        let a = AccelerometerAnalyzer()
        feed(a, from: 100, seconds: 1.0)
        feed(a, from: 101, seconds: 0.2, impactAt: 101.05, amplitude: 0.08)
        let hit = a.peak(from: 101.04, to: 101.07) ?? 0
        let quiet = a.peak(from: 100.5, to: 100.55) ?? 0
        #expect(hit > 0.03)
        #expect(quiet < 0.01)
    }

    @Test func slowTiltAndGravityAreRejected() {
        let a = AccelerometerAnalyzer()
        for i in 0..<1600 {   // slow 0.5 Hz rocking of 0.2 g
            let t = 50 + Double(i) / 800
            a.ingest(x: 0.2 * Float(sin(2 * .pi * 0.5 * t)), y: 0, z: -1, at: t)
        }
        #expect((a.peak(from: 51, to: 52) ?? 1) < 0.01)
    }

    @Test func harderTapMapsToHigherNormalisedStrength() {
        let a = AccelerometerAnalyzer()
        feed(a, from: 10, seconds: 1)
        // establish the user's typical strength with several medium taps
        var t = 11.0
        for _ in 0..<8 { feed(a, from: t, seconds: 0.25, impactAt: t + 0.05, amplitude: 0.04); _ = a.normalizedStrength(from: t + 0.04, to: t + 0.07); t += 0.25 }
        feed(a, from: t, seconds: 0.25, impactAt: t + 0.05, amplitude: 0.04)
        let medium = a.normalizedStrength(from: t + 0.04, to: t + 0.07) ?? 0
        t += 0.25
        feed(a, from: t, seconds: 0.25, impactAt: t + 0.05, amplitude: 0.16)
        let hard = a.normalizedStrength(from: t + 0.04, to: t + 0.07) ?? 0
        t += 0.25
        feed(a, from: t, seconds: 0.25, impactAt: t + 0.05, amplitude: 0.01)
        let soft = a.normalizedStrength(from: t + 0.04, to: t + 0.07)
        #expect(hard > medium)
        #expect(medium > 0.3 && medium < 0.7, "typical tap should map near 0.5, got \(medium)")
        #expect((soft ?? 0) < medium)
    }

    @Test func noiseOnlyYieldsNoStrength() {
        let a = AccelerometerAnalyzer()
        feed(a, from: 1, seconds: 1)
        #expect(a.normalizedStrength(from: 1.5, to: 1.52) == nil)
    }

    @Test func mapperIsNeutralAtZeroSensitivityAndMonotonic() {
        let neutral = IntensityMapper.map(strength: 1, sensitivity: 0)
        #expect(neutral.gain == 1 && neutral.pitch == 1)
        let mid = IntensityMapper.map(strength: 0.5, sensitivity: 1)
        #expect(abs(mid.gain - 1) < 0.001)
        var last: Float = 0
        for s in stride(from: 0.0, through: 1.0, by: 0.1) {
            let g = IntensityMapper.map(strength: s, sensitivity: 0.8).gain
            #expect(g > last); last = g
        }
        let extreme = IntensityMapper.map(strength: 1, sensitivity: 1)
        #expect(extreme.gain < 1.5 && extreme.pitch > 0.97, "effect must stay natural, not exaggerated")
        #expect(IntensityMapper.map(strength: nil, sensitivity: 1).gain == 1)
    }

    @Test func cadenceFallbackIsSubtle() {
        for dt in [0.02, 0.1, 0.2, 1.0] {
            let s = IntensityMapper.cadenceStrength(interval: dt)
            #expect(s > 0.35 && s < 0.65)
        }
    }
}
