import Foundation

/// Broad key families that get different sounds. Only the hardware key code is
/// ever inspected; typed characters are never read.
public enum KeyCategory: String, CaseIterable, Codable, Sendable {
    case alpha      // letters, digits, punctuation
    case space
    case enter
    case backspace
    case modifier   // shift, control, option, command, caps lock, fn
    case other      // tab, escape, arrows, function keys, ...
}

public enum KeyDirection: String, Sendable { case down, up }

public struct KeyAction: Equatable, Sendable {
    public var keyCode: UInt16
    public var category: KeyCategory
    public var direction: KeyDirection
    public var time: Double
    public init(keyCode: UInt16, category: KeyCategory, direction: KeyDirection, time: Double) {
        self.keyCode = keyCode; self.category = category; self.direction = direction; self.time = time
    }
}

public enum KeyClassifier {
    public static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    public static func category(forKeyCode code: UInt16) -> KeyCategory {
        switch code {
        case 49: return .space
        case 36, 76: return .enter
        case 51, 117: return .backspace
        case 54...63: return .modifier
        case 48, 53, 123...126, 115...116, 119...121, 122, 120, 99, 118, 96...98, 100...111: return .other
        default: return .alpha
        }
    }

    /// Approximate horizontal position of a key on an ANSI keyboard, 0 (left) to 1 (right).
    /// Used to pan sounds slightly so typing feels spatial.
    public static func horizontalPosition(forKeyCode code: UInt16) -> Double {
        let rows: [[UInt16]] = [
            [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24, 51],
            [48, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42],
            [57, 0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 36],
            [56, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44, 60],
        ]
        let offsets: [Double] = [0, 0.5, 0.75, 1.1]
        for (r, row) in rows.enumerated() {
            if let c = row.firstIndex(of: code) {
                let x = offsets[r] + Double(c)
                return min(1, max(0, x / 14.0))
            }
        }
        switch code {
        case 49: return 0.45
        case 123: return 0.82
        case 124: return 0.96
        case 125, 126: return 0.89
        case 55, 54: return code == 55 ? 0.25 : 0.7
        case 58, 61: return code == 58 ? 0.15 : 0.62
        case 59, 62: return code == 59 ? 0.05 : 0.8
        default: return 0.5
        }
    }
}

/// A raw keyboard event as reported by the event tap (key code and flags only).
public struct RawKeyEvent: Sendable {
    public enum Kind: Sendable { case keyDown, keyUp, flagsChanged }
    public var kind: Kind
    public var keyCode: UInt16
    public var isAutorepeat: Bool
    public var flags: UInt64
    public var time: Double
    public init(kind: Kind, keyCode: UInt16, isAutorepeat: Bool = false, flags: UInt64 = 0, time: Double) {
        self.kind = kind; self.keyCode = keyCode; self.isAutorepeat = isAutorepeat; self.flags = flags; self.time = time
    }
}

/// Turns raw tap events into clean key-down / key-up actions: drops auto-repeat and
/// duplicate events, and derives modifier press/release from flag changes.
public final class KeyEventProcessor {
    private var lock = os_unfair_lock()
    private var downTimes: [UInt16: Double] = [:]
    public static let duplicateWindow = 0.015

    private static let genericMask: [UInt16: UInt64] = [
        56: 0x20000, 60: 0x20000, 59: 0x40000, 62: 0x40000, 58: 0x80000, 61: 0x80000,
        55: 0x100000, 54: 0x100000, 63: 0x800000, 57: 0x10000,
    ]
    private static let deviceMask: [UInt16: UInt64] = [
        56: 0x2, 60: 0x4, 59: 0x1, 62: 0x2000, 58: 0x20, 61: 0x40, 55: 0x8, 54: 0x10,
    ]

    public init() { downTimes.reserveCapacity(32) }

    public func reset() {
        os_unfair_lock_lock(&lock); downTimes.removeAll(keepingCapacity: true); os_unfair_lock_unlock(&lock)
    }

    public func process(_ e: RawKeyEvent) -> KeyAction? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let category = KeyClassifier.category(forKeyCode: e.keyCode)
        switch e.kind {
        case .keyDown:
            if e.isAutorepeat { return nil }
            if let last = downTimes[e.keyCode], e.time - last < Self.duplicateWindow { return nil }
            downTimes[e.keyCode] = e.time
            return KeyAction(keyCode: e.keyCode, category: category, direction: .down, time: e.time)
        case .keyUp:
            guard downTimes.removeValue(forKey: e.keyCode) != nil else { return nil }
            return KeyAction(keyCode: e.keyCode, category: category, direction: .up, time: e.time)
        case .flagsChanged:
            guard KeyClassifier.modifierKeyCodes.contains(e.keyCode) else { return nil }
            let wasDown = downTimes[e.keyCode] != nil
            let generic = Self.genericMask[e.keyCode] ?? 0
            var isDown: Bool
            if e.keyCode == 57 {
                isDown = !wasDown   // caps lock only reports toggles
            } else if let device = Self.deviceMask[e.keyCode], e.flags & device != 0 {
                isDown = true
            } else if e.flags & generic == 0 {
                isDown = false
            } else {
                isDown = !wasDown
            }
            if isDown && !wasDown {
                downTimes[e.keyCode] = e.time
                return KeyAction(keyCode: e.keyCode, category: .modifier, direction: .down, time: e.time)
            } else if !isDown && wasDown {
                downTimes.removeValue(forKey: e.keyCode)
                return KeyAction(keyCode: e.keyCode, category: .modifier, direction: .up, time: e.time)
            }
            return nil
        }
    }
}
