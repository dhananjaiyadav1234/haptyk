import Testing
import Foundation
@testable import ThockCore

let rate = 48_000.0

@Suite("Synthesis and profiles")
struct SynthTests {
    @Test func sixRequiredProfilesExist() {
        let names = SoundProfiles.builtIn.map(\.name)
        for expected in ["Cherry MX Blue", "Cherry MX Red", "Cherry MX Brown", "Gateron Yellow", "Holy Panda", "Topre"] {
            #expect(names.contains(expected))
        }
        #expect(Set(SoundProfiles.all.map(\.id)).count == SoundProfiles.all.count)
    }

    @Test func everySlotIsAudibleBoundedAndFinite() {
        for p in SoundProfiles.builtIn {
            let bank = SoundBank(profile: p, sampleRate: rate)
            for c in KeyCategory.allCases {
                for d in [KeyDirection.down, .up] {
                    let v = bank.variants(c, d)
                    #expect(v.count == SoundBank.variantsPerSlot)
                    for b in v {
                        let peak = b.samples.map { abs($0) }.max() ?? 0
                        #expect(peak > 0.15, "\(p.id) \(c) \(d) too quiet")
                        #expect(peak <= 0.96, "\(p.id) \(c) \(d) too loud")
                        #expect(b.samples.allSatisfy { $0.isFinite })
                        #expect(abs(b.samples.last ?? 1) < 0.01, "sound should fade to silence")
                    }
                }
            }
        }
    }

    @Test func synthesisIsDeterministic() {
        let a = SoundBank(profile: SoundProfiles.default, sampleRate: rate).variants(.alpha, .down)[0].samples
        let b = SoundBank(profile: SoundProfiles.default, sampleRate: rate).variants(.alpha, .down)[0].samples
        #expect(a == b)
    }

    @Test func variantsDifferToAvoidRobotRepetition() {
        let v = SoundBank(profile: SoundProfiles.default, sampleRate: rate).variants(.alpha, .down)
        for i in 1..<v.count { #expect(v[0].samples != v[i].samples) }
    }

    @Test func profilesAreMeaningfullyDifferent() {
        var centroids: [(String, Double, Double)] = []
        for p in SoundProfiles.builtIn {
            let s = SoundBank(profile: p, sampleRate: rate).variants(.alpha, .down)[0].samples
            centroids.append((p.id, SpectralStats.centroid(s, sampleRate: rate), SpectralStats.decayTime(s, sampleRate: rate)))
        }
        for i in 0..<centroids.count {
            for j in (i + 1)..<centroids.count {
                let a = centroids[i], b = centroids[j]
                let centroidDiff = abs(a.1 - b.1) / max(a.1, b.1)
                let decayDiff = abs(a.2 - b.2) / max(a.2, b.2)
                #expect(centroidDiff > 0.12 || decayDiff > 0.2, "\(a.0) vs \(b.0) too similar (centroid \(Int(a.1))/\(Int(b.1)) Hz)")
            }
        }
        // sanity on character: clicky is brightest, Topre is darkest
        let sorted = centroids.sorted { $0.1 < $1.1 }
        #expect(sorted.first?.0 == "topre")
        #expect(sorted.last?.0 == "mx-blue")
    }

    @Test func specialKeysSoundDifferentFromLetters() {
        func fingerprint(_ s: [Float]) -> (Double, Double) {
            (SpectralStats.centroid(s, sampleRate: rate), SpectralStats.decayTime(s, sampleRate: rate))
        }
        for p in SoundProfiles.builtIn {
            let bank = SoundBank(profile: p, sampleRate: rate)
            let a = fingerprint(bank.variants(.alpha, .down)[0].samples)
            for special in [KeyCategory.space, .enter, .backspace, .modifier] {
                let f = fingerprint(bank.variants(special, .down)[0].samples)
                let differs = abs(f.0 - a.0) / a.0 > 0.03 || abs(f.1 - a.1) / a.1 > 0.08
                #expect(differs, "\(p.id) \(special) is indistinguishable from a letter")
            }
            let space = bank.variants(.space, .down)[0].samples
            #expect(space.count > bank.variants(.alpha, .down)[0].samples.count, "space bar should ring longer than a letter")
        }
    }

    @Test func releaseSoundIsQuieterOrShorterThanPress() {
        for p in SoundProfiles.builtIn {
            let bank = SoundBank(profile: p, sampleRate: rate)
            let down = bank.variants(.alpha, .down)[0].samples, up = bank.variants(.alpha, .up)[0].samples
            #expect(up.count < down.count)
        }
    }

    @Test func clickyProfileHasTransientEnergyOthersLack() {
        // Blue's click: strong energy above 2.5 kHz in the first 10 ms; Red has far less.
        func highEnergyRatio(_ id: String) -> Double {
            let s = SoundBank(profile: SoundProfiles.profile(id: id)!, sampleRate: rate).variants(.alpha, .down)[0].samples
            let early = Array(s.prefix(480))
            var hp = 0.0, prev: Float = 0, total = 0.0
            for x in early { let d = Double(x - prev); hp += d * d; total += Double(x * x); prev = x }
            return hp / max(total, 1e-9)
        }
        #expect(highEnergyRatio("mx-blue") > highEnergyRatio("mx-red") * 3)
    }

    @Test func wavEncoderProducesValidHeader() {
        let d = WAVWriter.data(samples: [0, 0.5, -0.5, 1], sampleRate: 48_000)
        #expect(d.count == 44 + 8)
        #expect(String(data: d.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: d.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
    }
}

@Suite("Voice mixer")
struct MixerTests {
    func render(_ m: VoiceMixer, frames: Int) -> ([Float], [Float]) {
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { l.deallocate(); r.deallocate() }
        m.render(frames: frames, left: l, right: r)
        return (Array(UnsafeBufferPointer(start: l, count: frames)), Array(UnsafeBufferPointer(start: r, count: frames)))
    }

    let ramp = SampleBuffer((0..<2000).map { Float(sin(Double($0) * 0.2)) * 0.5 })

    @Test func silentWhenIdle() {
        let m = VoiceMixer(); m.setVolume(1)
        let (l, r) = render(m, frames: 256)
        #expect(l.allSatisfy { $0 == 0 } && r.allSatisfy { $0 == 0 })
    }

    @Test func triggerProducesAudioWithinTheNextBlock() {
        let m = VoiceMixer(); m.setVolume(1)
        m.trigger(ramp, gain: 1, pan: 0, pitch: 1)
        let (l, _) = render(m, frames: 128)
        #expect(l.contains { abs($0) > 0.05 })
    }

    @Test func volumeScalesOutput() {
        func peak(_ v: Double) -> Float {
            let m = VoiceMixer(); m.setVolume(v)
            m.trigger(ramp, gain: 1, pan: 0, pitch: 1)
            let (l, _) = render(m, frames: 512)
            return l.map { abs($0) }.max() ?? 0
        }
        #expect(peak(1) > peak(0.5) * 2.5)
        #expect(peak(0) == 0)
    }

    @Test func panMovesSoundBetweenChannels() {
        let m = VoiceMixer(); m.setVolume(1)
        m.trigger(ramp, gain: 1, pan: -1, pitch: 1)
        let (l, r) = render(m, frames: 256)
        #expect((l.map { abs($0) }.max() ?? 0) > 0.1)
        #expect((r.map { abs($0) }.max() ?? 0) < 0.01)
    }

    @Test func pitchChangesPlaybackLength() {
        let m = VoiceMixer(); m.setVolume(1)
        m.trigger(ramp, gain: 1, pan: 0, pitch: 2)
        _ = render(m, frames: 600)
        #expect(m.activeVoiceCount == 1)
        _ = render(m, frames: 600)
        #expect(m.activeVoiceCount == 0)   // 2000 samples at 2x finished within 1200 frames
    }

    @Test func voicesFinishAndAreFreed() {
        let m = VoiceMixer(); m.setVolume(1)
        for _ in 0..<10 { m.trigger(ramp, gain: 0.3, pan: 0, pitch: 1) }
        _ = render(m, frames: 128)
        #expect(m.activeVoiceCount == 10)
        for _ in 0..<20 { _ = render(m, frames: 128) }
        #expect(m.activeVoiceCount == 0)
    }

    @Test func overloadStealsVoicesWithoutCrashOrClipping() {
        let m = VoiceMixer(); m.setVolume(1)
        for _ in 0..<500 { m.trigger(ramp, gain: 3, pan: 0.2, pitch: 1) }   // beyond queue capacity too
        for _ in 0..<10 {
            let (l, r) = render(m, frames: 256)
            #expect((l + r).allSatisfy { $0.isFinite && abs($0) <= 1.0 })
        }
        #expect(m.activeVoiceCount <= VoiceMixer.maxVoices)
    }

    @Test func latencyStatsAreRecorded() {
        let m = VoiceMixer(); m.setVolume(1)
        m.trigger(ramp, gain: 1, pan: 0, pitch: 1)
        _ = render(m, frames: 128)
        let s = m.latencyStats()
        #expect(s.count == 1 && s.mean >= 0 && s.max < 1)
    }

    @Test func renderCostIsFarBelowRealtimeBudget() {
        let bank = SoundBank(profile: SoundProfiles.default, sampleRate: rate)
        let m = VoiceMixer(); m.setVolume(0.8)
        for i in 0..<20 { m.trigger(bank.variants(.alpha, .down)[i % 6], gain: 0.5, pan: 0, pitch: 1) }
        let t0 = ProcessClock.now()
        for _ in 0..<100 { _ = render(m, frames: 128) }
        let perBlock = (ProcessClock.now() - t0) / 100
        #expect(perBlock < 128.0 / rate * 0.5, "mixer must use well under half the audio budget")
    }
}
