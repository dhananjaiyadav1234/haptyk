import Foundation

/// Monotonic clock in seconds, shared by the key tap, the sensor and the mixer
/// so timestamps from different threads can be compared directly.
public enum ProcessClock {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    public static func now() -> Double {
        Double(mach_absolute_time()) * timebase.numer / timebase.denom / 1_000_000_000
    }
}
