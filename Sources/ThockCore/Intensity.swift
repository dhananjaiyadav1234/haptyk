import Foundation

/// Source of per-keystroke "how hard was that press" information.
public protocol IntensitySource: AnyObject {
    var isStreaming: Bool { get }
    /// Strength in [0, 1+) of the physical tap around `time` (seconds on `ProcessClock`),
    /// or nil if the sensor saw nothing usable.
    func strength(around time: Double, before: Double, after: Double) -> Double?
}

/// Converts raw accelerometer samples into a high-passed vibration magnitude, tracks the
/// sensor's noise floor, and exposes the peak vibration inside a time window.
public final class AccelerometerAnalyzer {
    private var lock = os_unfair_lock()
    private let capacity = 4096
    private var times: [Double]
    private var values: [Float]
    private var head = 0
    private var filled = 0

    private var gx: Float = 0, gy: Float = 0, gz: Float = 0
    private var primed = false
    private let alpha: Float
    private var floorEstimate: Float = 0.003
    private var refStrength: Float = 0.02       // adaptive reference for "typical" keystroke
    private var sampleCount = 0
    private var firstSampleTime = 0.0
    private var lastSampleTime = 0.0

    /// - Parameter highPassAlpha: smoothing of the gravity/slow-motion estimate (per sample).
    public init(highPassAlpha: Float = 0.12) {
        alpha = highPassAlpha
        times = Array(repeating: 0, count: capacity)
        values = Array(repeating: 0, count: capacity)
    }

    public func ingest(x: Float, y: Float, z: Float, at time: Double) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if !primed { gx = x; gy = y; gz = z; primed = true; firstSampleTime = time }
        let dx = x - gx, dy = y - gy, dz = z - gz
        gx += alpha * dx; gy += alpha * dy; gz += alpha * dz
        let mag = (dx * dx + dy * dy + dz * dz).squareRoot()
        if mag < floorEstimate * 4 { floorEstimate += 0.0008 * (mag - floorEstimate) }
        floorEstimate = max(floorEstimate, 0.0004)
        times[head] = time; values[head] = mag
        head = (head + 1) % capacity
        filled = min(filled + 1, capacity)
        sampleCount += 1
        lastSampleTime = time
    }

    public var totalSamples: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return sampleCount }

    public var measuredRateHz: Double {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let span = lastSampleTime - firstSampleTime
        return span > 0.2 ? Double(sampleCount) / span : 0
    }

    public var lastSampleAge: Double {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return sampleCount == 0 ? .infinity : ProcessClock.now() - lastSampleTime
    }

    public var noiseFloor: Double { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return Double(floorEstimate) }

    /// Peak high-passed vibration (in g) between the two times, or nil if no samples fall inside.
    public func peak(from t0: Double, to t1: Double) -> Double? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        var best: Float = -1
        var idx = (head - 1 + capacity) % capacity
        var n = 0
        while n < filled {
            let t = times[idx]
            if t < t0 { break }
            if t <= t1 { best = max(best, values[idx]) }
            idx = (idx - 1 + capacity) % capacity
            n += 1
        }
        return best < 0 ? nil : Double(best)
    }

    /// Normalised keystroke strength: 0.5 means "typical for this user", > 0.5 harder, < 0.5 softer.
    /// Maintains an adaptive reference so it works regardless of desk, lap or palm-rest coupling.
    public func normalizedStrength(from t0: Double, to t1: Double) -> Double? {
        guard let p = peak(from: t0, to: t1) else { return nil }
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let s = max(0, p - 2.0 * Double(floorEstimate))
        if s < 0.0006 { return nil }                 // indistinguishable from noise
        let ratio = s / Double(max(refStrength, 0.001))
        refStrength += 0.08 * (Float(s) - refStrength)
        refStrength = max(refStrength, 0.002)
        return min(1, 0.5 * pow(ratio, 0.6))
    }
}

/// Maps a normalised strength (0...1) and a user sensitivity (0...1) to playback gain/pitch multipliers.
public enum IntensityMapper {
    public struct Result: Equatable { public var gain: Float; public var pitch: Double }

    public static func map(strength: Double?, sensitivity: Double) -> Result {
        let s = min(1, max(0, strength ?? 0.5))
        let sens = min(1, max(0, sensitivity))
        let rawGain = 0.55 + 0.9 * s            // 0.55 ... 1.45, neutral at 0.5
        let rawPitch = 1 + 0.05 * (s - 0.5)     // +-2.5 %
        return Result(gain: Float(1 + sens * (rawGain - 1)), pitch: 1 + sens * (rawPitch - 1))
    }

    /// Fallback when no sensor is available: typing cadence only, deliberately subtle.
    public static func cadenceStrength(interval: Double) -> Double {
        switch interval {
        case ..<0.06: return 0.42
        case ..<0.14: return 0.47
        case ..<0.40: return 0.52
        default: return 0.58
        }
    }
}

extension AccelerometerAnalyzer: IntensitySource {
    public var isStreaming: Bool { lastSampleAge < 0.5 }
    public func strength(around time: Double, before: Double, after: Double) -> Double? {
        normalizedStrength(from: time - before, to: time + after)
    }
}
