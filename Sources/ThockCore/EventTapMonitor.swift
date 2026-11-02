import Foundation
import CoreGraphics
import Carbon.HIToolbox

public enum InputPermission {
    /// Listening to keyboard events system-wide needs the "Input Monitoring" privilege.
    public static var isGranted: Bool { CGPreflightListenEventAccess() }
    @discardableResult public static func request() -> Bool { CGRequestListenEventAccess() }
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
    /// True while some app (typically a password field) has enabled Secure Event Input; macOS then
    /// hides keystrokes from every event tap, so no sounds can play. This is intentional OS behaviour.
    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }
}

/// Passive (listen-only) system-wide keyboard tap. It reads only the hardware key code, the
/// auto-repeat flag and modifier flags; characters, text and key strings are never touched,
/// stored or sent anywhere.
public final class EventTapMonitor {
    public enum State: Equatable { case stopped, running, needsPermission, failed }

    public private(set) var state: State = .stopped
    public let processor = KeyEventProcessor()
    public var onAction: ((KeyAction) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var watchdog: Timer?
    public private(set) var eventsSeen = 0

    public init() {}
    deinit { stop() }

    @discardableResult
    public func start() -> State {
        if state == .running { return .running }
        guard InputPermission.isGranted else { state = .needsPermission; return state }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<EventTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            state = InputPermission.isGranted ? .failed : .needsPermission
            return state
        }
        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
        source = src
        processor.reset()

        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            ready.signal()
            while let self, !Thread.current.isCancelled, self.tap != nil {
                CFRunLoopRunInMode(.defaultMode, 0.5, false)
            }
        }
        t.name = "Thock.EventTap"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        ready.wait()
        CGEvent.tapEnable(tap: port, enable: true)
        state = .running

        // The system disables a tap that stalls or that lost permission; verify periodically.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.verify() }
        return state
    }

    public func stop() {
        watchdog?.invalidate(); watchdog = nil
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        tap = nil
        if let src = source, let rl = runLoop { CFRunLoopRemoveSource(rl, src, .commonModes); CFRunLoopStop(rl) }
        thread?.cancel(); thread = nil; source = nil; runLoop = nil
        processor.reset()
        state = .stopped
    }

    private func verify() {
        guard let port = tap else { return }
        if !InputPermission.isGranted { stop(); state = .needsPermission; return }
        if !CGEvent.tapIsEnabled(tap: port) { CGEvent.tapEnable(tap: port, enable: true) }
        if !CGEvent.tapIsEnabled(tap: port) { stop(); state = .failed }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let kind: RawKeyEvent.Kind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return
        default: return
        }
        let raw = RawKeyEvent(kind: kind,
                              keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                              isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                              flags: event.flags.rawValue,
                              time: ProcessClock.now())
        eventsSeen += 1
        if let action = processor.process(raw) { onAction?(action) }
    }
}
