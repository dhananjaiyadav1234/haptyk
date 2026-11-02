import Foundation
import IOKit
import IOKit.hid

/// Reads the built-in accelerometer of Apple-silicon MacBooks (the "SPU" motion sensor, HID usage
/// page 0xFF00 / usage 3) through the ordinary IOHID user-space API. No root, no kernel extension and
/// no system modification beyond asking the driver for a report interval while this monitor runs.
///
/// This sensor is undocumented. Availability varies by model, and Apple may change it in any macOS
/// release, so everything here fails soft: if there is no device or no data the app silently uses
/// the typing-cadence fallback.
public final class SensorMonitor {
    public enum Status: Equatable {
        case stopped
        case unsupported          // no accelerometer device in the I/O registry
        case noData               // device present but not delivering reports
        case streaming(rateHz: Double)
    }

    public let analyzer = AccelerometerAnalyzer()
    public private(set) var status: Status = .stopped
    /// Report interval requested from the driver, in microseconds (about 500 Hz).
    public static let reportIntervalMicros = 2000

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var devices: [IOHIDDevice] = []
    private var driver: io_registry_entry_t = 0
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var stopRequested = false

    public init() {}
    deinit { stop() }

    /// True if this Mac exposes an accelerometer device at all.
    public static func deviceExists() -> Bool {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(mgr, matching() as CFDictionary)
        let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> ?? []
        return set.contains { IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) != nil }
    }

    static func matching() -> [String: Any] {
        [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3]
    }

    public func start() {
        guard thread == nil else { return }
        guard Self.deviceExists() else { status = .unsupported; return }
        stopRequested = false
        status = .noData
        analyzerReset()
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in self?.run(ready: ready) }
        t.name = "Thock.Sensor"
        t.qualityOfService = .userInitiated
        t.start()
        thread = t
        ready.wait()
    }

    public func stop() {
        guard thread != nil else { return }
        stopRequested = true
        if let rl = runLoop { CFRunLoopStop(rl) }
        thread = nil
        status = .stopped
    }

    /// Re-evaluates `status` from the real sample stream; call periodically (e.g. from a UI timer).
    public func refreshStatus() {
        guard thread != nil else { return }
        let rate = analyzer.measuredRateHz
        if analyzer.lastSampleAge < 1.0, rate > 0 { status = .streaming(rateHz: rate) } else { status = .noData }
    }

    private func analyzerReset() { /* analyzer is long-lived; its ring buffer is simply overwritten */ }

    private func run(ready: DispatchSemaphore) {
        runLoop = CFRunLoopGetCurrent()
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(mgr, Self.matching() as CFDictionary)
        let found = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
        devices = found.filter { IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) != nil }

        // Ask the sensor driver to start reporting (this is what Apple's own clients do).
        driver = Self.findDriver()
        if driver != 0 {
            IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString, Self.reportIntervalMicros as CFNumber)
        }

        let callback: IOHIDReportCallback = { context, _, _, _, _, report, length in
            guard let context, length >= 18 else { return }
            let monitor = Unmanaged<SensorMonitor>.fromOpaque(context).takeUnretainedValue()
            // Layout: 6-byte header, then x, y, z as little-endian Int32 in Q16.16 (units of g).
            func q16(_ o: Int) -> Float {
                let raw = UInt32(report[o]) | UInt32(report[o + 1]) << 8 | UInt32(report[o + 2]) << 16 | UInt32(report[o + 3]) << 24
                return Float(Int32(bitPattern: raw)) / 65536
            }
            monitor.analyzer.ingest(x: q16(6), y: q16(10), z: q16(14), at: ProcessClock.now())
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        for d in devices {
            guard IOHIDDeviceOpen(d, 0) == kIOReturnSuccess else { continue }
            let b = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
            buffers.append(b)
            IOHIDDeviceRegisterInputReportCallback(d, b, 256, callback, me)
            IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        ready.signal()
        while !stopRequested { CFRunLoopRunInMode(.defaultMode, 0.25, false) }

        for d in devices {
            IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(d, 0)
        }
        // Stop the stream so the sensor can go back to sleep (battery-friendly).
        if driver != 0 {
            IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString, 0 as CFNumber)
            IOObjectRelease(driver); driver = 0
        }
        buffers.forEach { $0.deallocate() }; buffers.removeAll(); devices.removeAll()
    }

    /// The AppleSPUHIDDriver instance that sits below the accelerometer HID device.
    static func findDriver() -> io_registry_entry_t {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &it) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(it) }
        var dev = IOIteratorNext(it)
        while dev != 0 {
            defer { IOObjectRelease(dev); dev = IOIteratorNext(it) }
            let usage = IORegistryEntryCreateCFProperty(dev, "PrimaryUsage" as CFString, nil, 0)?.takeRetainedValue() as? Int
            let page = IORegistryEntryCreateCFProperty(dev, "PrimaryUsagePage" as CFString, nil, 0)?.takeRetainedValue() as? Int
            guard usage == 3, page == 0xFF00,
                  IORegistryEntryCreateCFProperty(dev, "ProductID" as CFString, nil, 0) != nil else { continue }
            var ci: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(dev, "IOService", &ci) == KERN_SUCCESS else { continue }
            var child = IOIteratorNext(ci)
            while child != 0 {
                var gi: io_iterator_t = 0
                if IORegistryEntryGetChildIterator(child, "IOService", &gi) == KERN_SUCCESS {
                    var g = IOIteratorNext(gi)
                    while g != 0 {
                        var cls = [CChar](repeating: 0, count: 128)
                        IOObjectGetClass(g, &cls)
                        if String(cString: cls) == "AppleSPUHIDDriver" {
                            IOObjectRelease(gi); IOObjectRelease(child); IOObjectRelease(ci)
                            return g
                        }
                        IOObjectRelease(g); g = IOIteratorNext(gi)
                    }
                    IOObjectRelease(gi)
                }
                IOObjectRelease(child); child = IOIteratorNext(ci)
            }
            IOObjectRelease(ci)
        }
        return 0
    }
}
