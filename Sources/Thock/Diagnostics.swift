import Foundation
import ThockCore

/// Headless diagnostics: `Thock --render <dir>`, `--bench`, `--sensor-test`, `--tap-test`, `--help`.
enum Diagnostics {
    static func run(arguments a: [String]) -> Bool {
        switch a[0] {
        case "--render": render(to: a.count > 1 ? a[1] : "thock-samples"); return true
        case "--bench": bench(); return true
        case "--sensor-test": sensorTest(seconds: a.count > 1 ? Double(a[1]) ?? 5 : 5); return true
        case "--play-test": playTest(); return true
        case "--tap-test": tapTest(seconds: a.count > 1 ? Double(a[1]) ?? 10 : 10); return true
        case "--help", "-h":
            print("""
            Thock diagnostics
              --render <dir>        write every synthesized sound to WAV files and print spectral stats
              --bench               measure synthesis cost and real-time mixer cost
              --sensor-test [sec]   stream the built-in accelerometer and print what it sees
              --play-test           start the audio engine, play every profile's demo and report measured latency
              --tap-test [sec]      check Input Monitoring and count key events (key codes only)
            """)
            return true
        default: return false
        }
    }

    static func render(to dir: String) {
        let rate = 48_000.0
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        print("profile            slot            centroid(Hz)  decay-30dB(ms)")
        for p in SoundProfiles.all {
            let bank = SoundBank(profile: p, sampleRate: rate)
            for c in KeyCategory.allCases {
                for d in [KeyDirection.down, .up] {
                    guard let buf = bank.variants(c, d).first else { continue }
                    let centroid = SpectralStats.centroid(buf.samples, sampleRate: rate)
                    let decay = SpectralStats.decayTime(buf.samples, sampleRate: rate) * 1000
                    print(String(format: "%-18@ %-8@ %-5@ %10.0f %12.0f", p.id as NSString, c.rawValue as NSString, d.rawValue as NSString, centroid, decay))
                    let data = WAVWriter.data(samples: buf.samples, sampleRate: Int(rate))
                    try? data.write(to: URL(fileURLWithPath: "\(dir)/\(p.id)-\(c.rawValue)-\(d.rawValue).wav"))
                }
            }
        }
    }

    static func bench() {
        let rate = 48_000.0
        var t0 = ProcessClock.now()
        for p in SoundProfiles.all { _ = SoundBank(profile: p, sampleRate: rate) }
        print(String(format: "Synthesis: all %d profiles rendered in %.1f ms (%.1f ms per profile)",
                     SoundProfiles.all.count, (ProcessClock.now() - t0) * 1000, (ProcessClock.now() - t0) * 1000 / Double(SoundProfiles.all.count)))

        let bank = SoundBank(profile: SoundProfiles.default, sampleRate: rate)
        let mixer = VoiceMixer()
        mixer.setVolume(0.8)
        let frames = 128
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { l.deallocate(); r.deallocate() }
        // Worst case: 15 keys/s with presses and releases overlapping (about 30 voices alive).
        let blocks = Int(rate / Double(frames)) * 10
        var worst = 0.0, total = 0.0
        let buffers = bank.variants(.alpha, .down)
        var key = 0
        for b in 0..<blocks {
            if b % 20 == 0 { mixer.trigger(buffers[key % buffers.count], gain: 1, pan: 0, pitch: 1); key += 1 }
            let s = ProcessClock.now()
            mixer.render(frames: frames, left: l, right: r)
            let e = ProcessClock.now() - s
            worst = max(worst, e); total += e
        }
        let budget = Double(frames) / rate
        print(String(format: "Mixer: %d blocks of %d frames, mean %.1f µs, worst %.1f µs, budget %.0f µs → mean load %.3f %%, worst %.2f %%",
                     blocks, frames, total / Double(blocks) * 1e6, worst * 1e6, budget * 1e6, total / Double(blocks) / budget * 100, worst / budget * 100))
        t0 = ProcessClock.now()
    }

    static func sensorTest(seconds: Double) {
        print("Accelerometer device present: \(SensorMonitor.deviceExists())")
        let s = SensorMonitor()
        s.start()
        let end = ProcessClock.now() + seconds
        var maxPeak = 0.0
        print("Sampling for \(seconds)s — tap the palm rest to see peaks.")
        while ProcessClock.now() < end {
            Thread.sleep(forTimeInterval: 0.25)
            s.refreshStatus()
            let now = ProcessClock.now()
            let peak = s.analyzer.peak(from: now - 0.25, to: now) ?? 0
            maxPeak = max(maxPeak, peak)
            print(String(format: "status=%@  rate=%.0f Hz  noise floor=%.4f g  peak(250ms)=%.4f g", "\(s.status)", s.analyzer.measuredRateHz, s.analyzer.noiseFloor, peak))
        }
        s.stop()
        Thread.sleep(forTimeInterval: 0.6)
        print(String(format: "Total samples: %d, max peak: %.4f g", s.analyzer.totalSamples, maxPeak))
    }

    static func playTest() {
        let mixer = VoiceMixer()
        let audio = AudioOutput(mixer: mixer)
        let coordinator = KeySoundCoordinator(mixer: mixer, sampleRate: { audio.outputSampleRate })
        var settings = ThockSettings(); settings.volume = 0.5
        coordinator.apply(settings, synchronous: true)
        guard audio.start() else { print("audio engine failed to start"); return }
        let i = audio.info
        print("device: \(i.deviceName), \(Int(i.sampleRate)) Hz, buffer \(i.bufferFrames) frames, estimated output latency \(String(format: "%.1f", i.estimatedOutputLatencyMs)) ms")
        for p in SoundProfiles.all {
            print("playing \(p.name)…")
            coordinator.preview(profileID: p.id)
            Thread.sleep(forTimeInterval: 2.0)
        }
        let l = mixer.latencyStats()
        print(String(format: "triggers rendered: %d, trigger→render-callback delay: mean %.2f ms, max %.2f ms", l.count, l.mean * 1000, l.max * 1000))
        audio.stop()
    }

    static func tapTest(seconds: Double) {
        print("Input Monitoring granted: \(InputPermission.isGranted)")
        let m = EventTapMonitor()
        var downs = 0, ups = 0
        m.onAction = { a in if a.direction == .down { downs += 1 } else { ups += 1 } }
        print("tap state: \(m.start())")
        if m.state == .running {
            print("Type on the keyboard for \(seconds)s (only counts are shown)…")
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }
        print("key-downs: \(downs), key-ups: \(ups), raw events: \(m.eventsSeen)")
        m.stop()
    }
}
