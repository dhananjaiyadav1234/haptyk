import Foundation

/// Real-time polyphonic sample player. `trigger` may be called from any thread (it only
/// appends to a pre-allocated queue under a very short lock); `render` runs on the audio thread.
public final class VoiceMixer {
    public static let maxVoices = 48
    public static let queueCapacity = 128

    struct Pending {
        var buffer: SampleBuffer
        var gainL: Float
        var gainR: Float
        var step: Double
        var queuedAt: Double
    }
    struct Voice {
        var buffer: SampleBuffer?
        var pos: Double = 0
        var step: Double = 1
        var gainL: Float = 0
        var gainR: Float = 0
        var serial: UInt64 = 0
    }

    private var lock = os_unfair_lock()
    private var pending: [Pending] = []
    private var voices: [Voice]
    private var serial: UInt64 = 0
    private var masterTarget: Float = 0.5
    private var masterCurrent: Float = 0.5

    // Genuine latency statistics: time from trigger() to the start of the render block that picks it up.
    private var latencySum = 0.0, latencyMax = 0.0, latencyCount = 0

    public init() {
        pending.reserveCapacity(Self.queueCapacity)
        voices = Array(repeating: Voice(), count: Self.maxVoices)
    }

    public func setVolume(_ v: Double) {
        let c = Float(min(1, max(0, v)))
        os_unfair_lock_lock(&lock); masterTarget = c * c; os_unfair_lock_unlock(&lock)
    }

    /// pan: -1 (left) ... 1 (right). pitch: playback-rate ratio. gain: linear.
    public func trigger(_ buffer: SampleBuffer, gain: Float, pan: Float, pitch: Double) {
        let p = min(1, max(-1, pan))
        let angle = Double((p + 1) * 0.25) * Double.pi   // constant-power pan
        let l = Float(cos(angle)) * gain * 1.4142135
        let r = Float(sin(angle)) * gain * 1.4142135
        let item = Pending(buffer: buffer, gainL: l, gainR: r, step: pitch, queuedAt: ProcessClock.now())
        os_unfair_lock_lock(&lock)
        if pending.count < Self.queueCapacity { pending.append(item) }
        os_unfair_lock_unlock(&lock)
    }

    public var activeVoiceCount: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return voices.reduce(0) { $0 + ($1.buffer != nil ? 1 : 0) } + pending.count
    }

    public func latencyStats() -> (mean: Double, max: Double, count: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return (latencyCount > 0 ? latencySum / Double(latencyCount) : 0, latencyMax, latencyCount)
    }

    public func resetLatencyStats() {
        os_unfair_lock_lock(&lock); latencySum = 0; latencyMax = 0; latencyCount = 0; os_unfair_lock_unlock(&lock)
    }

    /// Mixes `frames` stereo frames into left/right (overwriting them).
    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let renderStart = ProcessClock.now()
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        memset(left, 0, frames * MemoryLayout<Float>.size)
        memset(right, 0, frames * MemoryLayout<Float>.size)

        // A volume change made while nothing is playing must apply from the first sample of the next sound.
        if !voices.contains(where: { $0.buffer != nil }) { masterCurrent = masterTarget }

        if !pending.isEmpty {
            for p in pending {
                let wait = max(0, renderStart - p.queuedAt)
                latencySum += wait; latencyCount += 1; latencyMax = max(latencyMax, wait)
                serial &+= 1
                var slot = -1
                for i in 0..<voices.count where voices[i].buffer == nil { slot = i; break }
                if slot < 0 {   // steal the oldest voice
                    var oldest = UInt64.max
                    for i in 0..<voices.count where voices[i].serial < oldest { oldest = voices[i].serial; slot = i }
                }
                voices[slot] = Voice(buffer: p.buffer, pos: 0, step: p.step, gainL: p.gainL, gainR: p.gainR, serial: serial)
            }
            pending.removeAll(keepingCapacity: true)
        }

        var anyActive = false
        for v in 0..<voices.count {
            guard let buf = voices[v].buffer else { continue }
            anyActive = true
            let count = buf.count
            var pos = voices[v].pos
            let step = voices[v].step
            let gl = voices[v].gainL, gr = voices[v].gainR
            var finished = false
            buf.samples.withUnsafeBufferPointer { s in
                for i in 0..<frames {
                    let idx = Int(pos)
                    if idx >= count - 1 { finished = true; break }
                    let frac = Float(pos - Double(idx))
                    let sample = s[idx] + (s[idx + 1] - s[idx]) * frac
                    left[i] += sample * gl
                    right[i] += sample * gr
                    pos += step
                }
            }
            if finished { voices[v].buffer = nil } else { voices[v].pos = pos }
        }

        // Smoothed master gain + soft limiter.
        if !anyActive { masterCurrent = masterTarget; return }
        let delta = (masterTarget - masterCurrent) / Float(max(frames, 1))
        for i in 0..<frames {
            masterCurrent += delta
            left[i] = Self.soften(left[i] * masterCurrent)
            right[i] = Self.soften(right[i] * masterCurrent)
        }
        masterCurrent = masterTarget
    }

    @inline(__always) static func soften(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.8 { return x }
        let y = 0.8 + 0.2 * tanhf((a - 0.8) / 0.2)
        return x < 0 ? -y : y
    }
}
