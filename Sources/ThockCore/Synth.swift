import Foundation

/// Small deterministic PRNG so synthesized sounds are reproducible (and testable).
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func signed() -> Double { unit() * 2 - 1 }
}

/// One component of a key sound.
public enum Layer: Equatable, Sendable {
    /// Decaying sinusoid (resonance of the case / plate). `glide` is the fractional pitch drop over the decay.
    case tone(freq: Double, decay: Double, amp: Double, delay: Double, glide: Double)
    /// Band-limited noise burst (plastic click, bottom-out impact, stabiliser rattle).
    case noise(center: Double, q: Double, decay: Double, amp: Double, delay: Double)
}

public struct Recipe: Equatable, Sendable {
    public var layers: [Layer]
    public var lowpassHz: Double
    public var level: Float
    public var duration: Double
    public init(layers: [Layer], lowpassHz: Double, level: Float, duration: Double) {
        self.layers = layers; self.lowpassHz = lowpassHz; self.level = level; self.duration = duration
    }

    /// Returns a slightly perturbed copy (frequencies, decays, amplitudes) so repeated
    /// presses do not sound identical.
    func varied(using rng: inout SplitMix64, amount: Double = 1) -> Recipe {
        var r = self
        r.layers = layers.map { layer in
            switch layer {
            case let .tone(f, d, a, t, g):
                return .tone(freq: f * (1 + 0.025 * amount * rng.signed()),
                             decay: d * (1 + 0.10 * amount * rng.signed()),
                             amp: a * (1 + 0.10 * amount * rng.signed()),
                             delay: max(0, t * (1 + 0.1 * amount * rng.signed())), glide: g)
            case let .noise(c, q, d, a, t):
                return .noise(center: c * (1 + 0.04 * amount * rng.signed()), q: q,
                              decay: d * (1 + 0.10 * amount * rng.signed()),
                              amp: a * (1 + 0.12 * amount * rng.signed()),
                              delay: max(0, t * (1 + 0.1 * amount * rng.signed())))
            }
        }
        return r
    }
}

public enum SoundSynth {
    /// Renders a recipe to mono Float samples in [-level, level].
    public static func render(_ recipe: Recipe, sampleRate: Double, seed: UInt64) -> [Float] {
        let n = max(16, Int(recipe.duration * sampleRate))
        var out = [Double](repeating: 0, count: n)
        var rng = SplitMix64(seed: seed)
        let twoPi = 2 * Double.pi

        for layer in recipe.layers {
            switch layer {
            case let .tone(freq, decay, amp, delay, glide):
                let start = Int(delay * sampleRate)
                guard start < n, decay > 0 else { continue }
                var phase = rng.unit() * twoPi
                var i = start
                while i < n {
                    let t = Double(i - start) / sampleRate
                    let env = exp(-t / decay)
                    if env < 0.0005 { break }
                    let attack = min(1, t / 0.0004)
                    let f = freq * (1 - glide * (1 - env))
                    phase += twoPi * f / sampleRate
                    out[i] += amp * env * attack * sin(phase)
                    i += 1
                }
            case let .noise(center, q, decay, amp, delay):
                let start = Int(delay * sampleRate)
                guard start < n, decay > 0 else { continue }
                let f = min(center, sampleRate * 0.45)
                let w0 = twoPi * f / sampleRate
                let alpha = sin(w0) / (2 * q)
                let a0 = 1 + alpha
                let b0 = alpha / a0, b2 = -alpha / a0
                let a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
                let comp = min(6, max(0.5, (sampleRate / 2 / max(f / q, 50)).squareRoot() * 0.35))
                var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
                var i = start
                while i < n {
                    let t = Double(i - start) / sampleRate
                    let env = exp(-t / decay)
                    if env < 0.0005 { break }
                    let attack = min(1, t / 0.0002)
                    let x0 = rng.signed()
                    let y0 = b0 * x0 + b2 * x2 - a1 * y1 - a2 * y2
                    x2 = x1; x1 = x0; y2 = y1; y1 = y0
                    out[i] += amp * comp * env * attack * y0
                    i += 1
                }
            }
        }

        // Two cascaded one-pole low-passes = soft 12 dB/oct roll-off ("brightness").
        let k = 1 - exp(-twoPi * min(recipe.lowpassHz, sampleRate * 0.45) / sampleRate)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<n {
            s1 += k * (out[i] - s1)
            s2 += k * (s1 - s2)
            out[i] = s2
        }

        var peak = 0.0
        for v in out { peak = max(peak, abs(v)) }
        let scale = peak > 1e-9 ? Double(recipe.level) / peak : 0
        let fade = max(1, Int(0.004 * sampleRate))
        var result = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var v = out[i] * scale
            if i >= n - fade { v *= Double(n - i) / Double(fade) }
            result[i] = Float(v)
        }
        return result
    }
}

/// Immutable mono sample data shared between the sound bank and playing voices.
public final class SampleBuffer: @unchecked Sendable {
    public let samples: [Float]
    public init(_ samples: [Float]) { self.samples = samples }
    public var count: Int { samples.count }
}

public struct SoundSlot: Hashable, Sendable {
    public var category: KeyCategory
    public var direction: KeyDirection
}

/// All pre-rendered variants for one profile at one sample rate.
public final class SoundBank: @unchecked Sendable {
    public static let variantsPerSlot = 6
    public let profile: SoundProfile
    public let sampleRate: Double
    private var slots: [SoundSlot: [SampleBuffer]] = [:]

    public init(profile: SoundProfile, sampleRate: Double) {
        self.profile = profile
        self.sampleRate = sampleRate
        var baseSeed: UInt64 = 1469598103934665603
        for b in profile.id.utf8 { baseSeed = (baseSeed ^ UInt64(b)) &* 1099511628211 }
        for category in KeyCategory.allCases {
            for direction in [KeyDirection.down, .up] {
                let base = SoundDesigner.recipe(for: profile.spec, category: category, direction: direction)
                var rng = SplitMix64(seed: baseSeed &+ UInt64(category.hashValueStable) &* 31 &+ (direction == .down ? 7 : 13))
                var buffers: [SampleBuffer] = []
                for v in 0..<Self.variantsPerSlot {
                    let r = base.varied(using: &rng)
                    let samples = SoundSynth.render(r, sampleRate: sampleRate, seed: rng.next() ^ UInt64(v))
                    buffers.append(SampleBuffer(samples))
                }
                slots[SoundSlot(category: category, direction: direction)] = buffers
            }
        }
    }

    public func variants(_ category: KeyCategory, _ direction: KeyDirection) -> [SampleBuffer] {
        slots[SoundSlot(category: category, direction: direction)] ?? []
    }
}

extension KeyCategory {
    /// `hashValue` is randomised per process; this is stable so sounds are reproducible between launches.
    var hashValueStable: Int { KeyCategory.allCases.firstIndex(of: self) ?? 0 }
}
