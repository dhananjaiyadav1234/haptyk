import Foundation
import AVFoundation
import CoreAudio

/// Owns the AVAudioEngine and feeds it from the VoiceMixer through a render callback,
/// so there is no scheduling overhead between a keystroke and the audio buffer.
public final class AudioOutput {
    public struct Info: Equatable {
        public var sampleRate: Double = 0
        public var bufferFrames: Int = 0
        public var deviceLatencyFrames: Int = 0
        public var deviceName: String = "—"
        /// Output-side latency from Core Audio properties (buffer + device latency + safety offset), in ms.
        public var estimatedOutputLatencyMs: Double = 0
        public init() {}
    }

    public let mixer: VoiceMixer
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var observer: NSObjectProtocol?
    public private(set) var isRunning = false
    public private(set) var info = Info()
    public var onConfigurationChange: (() -> Void)?

    public init(mixer: VoiceMixer) { self.mixer = mixer }

    deinit { stop() }

    /// Sample rate the engine will run at (queried before start so banks can be rendered to match).
    public var outputSampleRate: Double {
        let r = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return r > 0 ? r : 48_000
    }

    @discardableResult
    public func start() -> Bool {
        if isRunning { return true }
        let rate = outputSampleRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false) else { return false }
        let mixer = self.mixer
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2,
                  let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            mixer.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        requestSmallBuffer()
        engine.prepare()
        do { try engine.start() } catch {
            engine.detach(node); sourceNode = nil
            NSLog("Thock: audio engine failed to start: \(error)")
            return false
        }
        isRunning = true
        info = Self.queryInfo()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        return true
    }

    public func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        guard isRunning || sourceNode != nil else { return }
        engine.stop()
        if let n = sourceNode { engine.detach(n); sourceNode = nil }
        isRunning = false
    }

    public func restart() { stop(); start() }

    private func handleConfigurationChange() {
        // Output device or sample rate changed (headphones, AirPlay, wake from sleep...).
        let wasRunning = isRunning
        stop()
        onConfigurationChange?()
        if wasRunning { start() }
    }

    // MARK: Core Audio helpers

    private static func defaultOutputDevice() -> AudioObjectID {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    private func requestSmallBuffer() {
        // Ask for a 128-frame IO buffer (about 2.7 ms at 48 kHz) if the device allows it.
        let dev = Self.defaultOutputDevice()
        guard dev != kAudioObjectUnknown else { return }
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var rangeAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &rangeAddr, 0, nil, &size, &range) == noErr else { return }
        var frames = UInt32(min(max(128, range.mMinimum), range.mMaximum))
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
    }

    static func queryInfo() -> Info {
        var info = Info()
        let dev = defaultOutputDevice()
        guard dev != kAudioObjectUnknown else { return info }

        func u32(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
            var v: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v)
            return v
        }
        var rate = Float64(0)
        var rsize = UInt32(MemoryLayout<Float64>.size)
        var raddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(dev, &raddr, 0, nil, &rsize, &rate)
        let buffer = Int(u32(kAudioDevicePropertyBufferFrameSize))
        let latency = Int(u32(kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput))
        let safety = Int(u32(kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput))
        info.sampleRate = rate
        info.bufferFrames = buffer
        info.deviceLatencyFrames = latency
        if rate > 0 { info.estimatedOutputLatencyMs = Double(buffer + latency + safety) / rate * 1000 }

        var name: Unmanaged<CFString>?
        var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var naddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(dev, &naddr, 0, nil, &nsize, &name) == noErr, let n = name {
            info.deviceName = n.takeRetainedValue() as String
        }
        return info
    }
}
