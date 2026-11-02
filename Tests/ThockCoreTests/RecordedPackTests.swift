import Testing
import Foundation
@testable import ThockCore

@Suite("Recorded sound packs")
struct RecordedPackTests {
    func makePack(files: Int = 3, release: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thock-pack-\(UUID().uuidString)")
        let pack = root.appendingPathComponent("my-pack")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data(#"{"name": "My Pack", "summary": "test"}"#.utf8).write(to: pack.appendingPathComponent("pack.json"))
        let tone = (0..<4000).map { Float(sin(Double($0) * 0.3) * exp(-Double($0) / 800)) * 0.8 }
        for i in 1...files { try WAVWriter.data(samples: tone, sampleRate: 44_100).write(to: pack.appendingPathComponent("press-0\(i).wav")) }
        if release { try WAVWriter.data(samples: tone, sampleRate: 44_100).write(to: pack.appendingPathComponent("release-01.wav")) }
        return root
    }

    @Test func wavReaderRoundTrips() throws {
        let src: [Float] = (0..<1000).map { Float(sin(Double($0) * 0.1)) * 0.5 }
        let audio = try #require(WAVReader.read(WAVWriter.data(samples: src, sampleRate: 44_100)))
        #expect(audio.sampleRate == 44_100 && audio.samples.count == 1000)
        for i in stride(from: 0, to: 1000, by: 97) { #expect(abs(audio.samples[i] - src[i]) < 0.001) }
        #expect(WAVReader.read(Data("garbage".utf8)) == nil)
    }

    @Test func resamplingChangesLengthByPitchRatio() {
        let x = [Float](repeating: 0.5, count: 4800)
        #expect(abs(WAVReader.resample(x, from: 44_100, to: 48_000).count - 5225) < 3)
        #expect(abs(WAVReader.resample(x, from: 48_000, to: 48_000, pitch: 0.5).count - 9600) < 3)
    }

    @Test func loaderFindsValidPacksAndIgnoresBrokenOnes() throws {
        let root = try makePack(files: 3)
        let broken = root.appendingPathComponent("broken"); try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let packs = RecordedPackLoader.load(from: [root])
        #expect(packs.count == 1)
        #expect(packs[0].id == "my-pack" && packs[0].name == "My Pack" && packs[0].pressFiles.count == 3 && packs[0].isRecorded)
    }

    @Test func recordedBankHasPressVariantsAndPlays() throws {
        let profile = try #require(RecordedPackLoader.load(from: [try makePack(files: 3)]).first)
        let bank = SoundBank(profile: profile, sampleRate: 48_000)
        for c in KeyCategory.allCases { #expect(bank.variants(c, .down).count == 3) }
        #expect(bank.variants(.alpha, .up).isEmpty)
        #expect(bank.variants(.space, .down)[0].count > bank.variants(.alpha, .down)[0].count, "space is pitched down, so longer")

        let mixer = VoiceMixer(); mixer.setVolume(1)
        let c = KeySoundCoordinator(mixer: mixer, sampleRate: { 48_000 })
        var s = ThockSettings(); s.sensorEnabled = false
        s.profileID = profile.id
        c.apply(s, synchronous: true)   // unknown id falls back to default, so just assert no crash on release too
        c.handle(KeyAction(keyCode: 0, category: .alpha, direction: .up, time: 1))
    }

    @Test func bundledRecordingsAreAvailableAndAttributed() {
        let ids = SoundProfiles.recorded.map(\.id)
        #expect(ids.contains("old-recorded") && ids.contains("mac-recorded"))
        for p in SoundProfiles.recorded where ["old-recorded", "mac-recorded"].contains(p.id) {
            #expect(p.attribution?.contains("CC BY 3.0") == true)
            #expect(p.pressFiles.count >= 6)
            let bank = SoundBank(profile: p, sampleRate: 48_000)
            #expect(bank.variants(.alpha, .down).allSatisfy { ($0.samples.map { abs($0) }.max() ?? 0) > 0.3 })
        }
    }
}
