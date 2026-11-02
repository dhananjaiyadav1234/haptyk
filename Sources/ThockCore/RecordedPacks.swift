import Foundation

/// Minimal PCM WAV reader (8/16/24/32-bit integer or 32-bit float; mixes to mono).
public enum WAVReader {
    public struct Audio { public var samples: [Float]; public var sampleRate: Double }

    public static func read(_ data: Data) -> Audio? {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count > 44, String(decoding: b[0..<4], as: UTF8.self) == "RIFF", String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        var pos = 12
        var format = 1, channels = 1, rate = 44_100, bits = 16
        var pcm: Range<Int>?
        while pos + 8 <= b.count {
            let id = String(decoding: b[pos..<pos + 4], as: UTF8.self)
            let size = u32(pos + 4)
            let body = pos + 8
            if id == "fmt ", body + 16 <= b.count {
                format = u16(body); channels = max(1, u16(body + 2)); rate = u32(body + 4); bits = u16(body + 14)
            } else if id == "data" {
                pcm = body..<min(b.count, body + size)
            }
            pos = body + size + (size & 1)
        }
        guard let range = pcm, rate > 0, (format == 1 && [8, 16, 24, 32].contains(bits)) || (format == 3 && bits == 32) else { return nil }
        let bytes = bits / 8, frame = bytes * channels
        let frames = range.count / frame
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels {
                let o = range.lowerBound + i * frame + c * bytes
                switch (format, bits) {
                case (1, 8): sum += (Float(b[o]) - 128) / 128
                case (1, 16): sum += Float(Int16(bitPattern: UInt16(u16(o)))) / 32768
                case (1, 24):
                    var v = Int32(b[o]) | Int32(b[o + 1]) << 8 | Int32(b[o + 2]) << 16
                    if v & 0x800000 != 0 { v |= ~0xFFFFFF }
                    sum += Float(v) / 8_388_608
                case (1, 32): sum += Float(Int32(bitPattern: UInt32(u32(o)))) / 2_147_483_648
                default: sum += Float(bitPattern: UInt32(u32(o)))
                }
            }
            out[i] = sum / Float(channels)
        }
        return Audio(samples: out, sampleRate: Double(rate))
    }

    /// Linear-interpolated resample by `ratio` (playback-rate ratio; > 1 = higher pitch, shorter), also converting rates.
    public static func resample(_ x: [Float], from: Double, to: Double, pitch: Double = 1) -> [Float] {
        let step = from / to * pitch
        guard x.count > 1, step > 0 else { return x }
        let n = Int(Double(x.count - 1) / step)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = Double(i) * step
            let k = Int(p)
            let f = Float(p - Double(k))
            out[i] = x[k] + (x[k + 1] - x[k]) * f
        }
        return out
    }
}

/// Looks for real-recording sound packs: folders containing `pack.json` and `press-*.wav`
/// (optionally `release-*.wav`). Bundled packs live in the app's Resources; users can drop their own
/// packs into ~/Library/Application Support/Thock/Packs/<name>/.
public enum RecordedPackLoader {
    struct Meta: Decodable { var name: String; var summary: String?; var attribution: String? }

    public static var searchDirectories: [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("RecordedKeys")) }
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/RecordedKeys"))
        if let s = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dirs.append(s.appendingPathComponent("Thock/Packs"))
        }
        return dirs
    }

    public static func load(from directories: [URL] = searchDirectories) -> [SoundProfile] {
        var found: [SoundProfile] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for dir in directories {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for folder in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let id = folder.lastPathComponent
                guard !seen.contains(id),
                      let metaData = try? Data(contentsOf: folder.appendingPathComponent("pack.json")),
                      let meta = try? JSONDecoder().decode(Meta.self, from: metaData),
                      let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
                let press = files.filter { $0.lastPathComponent.hasPrefix("press") && $0.pathExtension.lowercased() == "wav" }.sorted { $0.path < $1.path }
                let release = files.filter { $0.lastPathComponent.hasPrefix("release") && $0.pathExtension.lowercased() == "wav" }.sorted { $0.path < $1.path }
                guard !press.isEmpty else { continue }
                seen.insert(id)
                var p = SoundProfile(id: id, name: meta.name, summary: meta.summary ?? "Recorded sound pack.", spec: SoundProfiles.builtIn[0].spec)
                p.pressFiles = press
                p.releaseFiles = release
                p.attribution = meta.attribution
                found.append(p)
            }
        }
        return found
    }
}
