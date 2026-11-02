import Foundation

public enum WAVWriter {
    /// Encodes mono 16-bit PCM.
    public static func data(samples: [Float], sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = samples.count * 2
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + bytes)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(bytes))
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return d
    }
}

/// Simple spectral descriptors used for tests and the `--analyze` diagnostic.
public enum SpectralStats {
    /// Magnitude-weighted spectral centroid (Hz) using a direct DFT over the first `length` samples.
    public static func centroid(_ x: [Float], sampleRate: Double, length: Int = 2048) -> Double {
        let n = min(length, x.count)
        guard n > 8 else { return 0 }
        var num = 0.0, den = 0.0
        let bins = n / 2
        var k = 1
        while k < bins {
            var re = 0.0, im = 0.0
            let w = 2 * Double.pi * Double(k) / Double(n)
            for i in 0..<n {
                let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
                let v = Double(x[i]) * hann
                re += v * cos(w * Double(i)); im -= v * sin(w * Double(i))
            }
            let mag = (re * re + im * im).squareRoot()
            let f = Double(k) * sampleRate / Double(n)
            num += f * mag; den += mag
            k += 1
        }
        return den > 0 ? num / den : 0
    }

    /// Time in seconds for the RMS envelope to fall 30 dB below its peak (measured in 2 ms windows).
    public static func decayTime(_ x: [Float], sampleRate: Double) -> Double {
        let win = max(1, Int(0.002 * sampleRate))
        var env: [Double] = []
        var i = 0
        while i + win <= x.count {
            var s = 0.0
            for j in i..<(i + win) { s += Double(x[j]) * Double(x[j]) }
            env.append((s / Double(win)).squareRoot()); i += win
        }
        guard let peakIdx = env.indices.max(by: { env[$0] < env[$1] }) else { return 0 }
        let threshold = env[peakIdx] * 0.0316
        for j in peakIdx..<env.count where env[j] < threshold { return Double(j - peakIdx) * 0.002 }
        return Double(env.count - peakIdx) * 0.002
    }
}
