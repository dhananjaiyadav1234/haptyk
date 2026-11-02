import AppKit
import Combine
import ThockCore

/// Live vibration level. Kept separate from AppController so its 15 Hz updates only redraw the meter.
@MainActor
final class SensorMeter: ObservableObject {
    @Published var level = 0.0
}

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published var settings: ThockSettings {
        didSet { if settings != oldValue { settingsChanged() } }
    }
    @Published private(set) var inputGranted = InputPermission.isGranted
    @Published private(set) var tapState: EventTapMonitor.State = .stopped
    @Published private(set) var secureInput = false
    @Published private(set) var sensorStatus: SensorMonitor.Status = .stopped
    let meter = SensorMeter()
    @Published private(set) var audioInfo = AudioOutput.Info()
    @Published private(set) var queueLatency: (mean: Double, max: Double, count: Int) = (0, 0, 0)
    @Published private(set) var launchAtLogin = LoginItem.isEnabled
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var keysHeard = 0

    private let store = SettingsStore()
    let mixer = VoiceMixer()
    let audio: AudioOutput
    let coordinator: KeySoundCoordinator
    let tap = EventTapMonitor()
    let sensor = SensorMonitor()
    private var pollTimer: Timer?
    private var meterTimer: Timer?
    private var previewStopWork: DispatchWorkItem?

    private init() {
        let audio = AudioOutput(mixer: mixer)
        self.audio = audio
        self.coordinator = KeySoundCoordinator(mixer: mixer, sampleRate: { audio.outputSampleRate })
        self.settings = store.load()
        coordinator.intensitySource = sensor.analyzer
        tap.onAction = { [coordinator] action in coordinator.handle(action) }
        audio.onConfigurationChange = { [weak self] in
            guard let self else { return }
            self.coordinator.invalidateBanks()
            self.coordinator.apply(self.settings)
        }
    }

    func start() {
        reconcile()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Give the audio hardware and window server a moment to come back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Task { @MainActor in self?.recoverAfterWake() } }
        }
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sensor.stop() }
        }
    }

    func shutdown() {
        tap.stop(); sensor.stop(); audio.stop()
    }

    // MARK: State changes

    private func settingsChanged() {
        store.save(settings)
        reconcile()
    }

    /// Brings tap, audio engine and sensor in line with the settings. Idle (disabled/muted) means
    /// no event tap, no audio engine and no sensor, so the app costs essentially nothing.
    func reconcile() {
        coordinator.apply(settings)
        if settings.isAudible {
            if !audio.isRunning { audio.start() }
            if tap.state != .running { tap.start() }
            if settings.sensorEnabled { sensor.start() } else { sensor.stop() }
        } else {
            tap.stop()
            sensor.stop()
            if previewStopWork == nil { audio.stop() }
        }
        refreshStatus()
    }

    private func recoverAfterWake() {
        guard settings.isAudible else { return }
        tap.stop(); sensor.stop(); audio.restart()
        coordinator.invalidateBanks(); coordinator.apply(settings)
        tap.start()
        if settings.sensorEnabled { sensor.start() }
        refreshStatus()
    }

    private func poll() {
        // Pick up a permission grant without requiring a relaunch.
        if settings.isAudible, tap.state != .running { tap.start() }
        if settings.isAudible, !audio.isRunning, previewStopWork == nil { audio.start() }
        refreshStatus()
    }

    private func refreshStatus() {
        // Assign only on change: @Published fires on every assignment and would redraw the UI each second.
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppController, T>, _ value: T) {
            if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
        }
        set(\.inputGranted, InputPermission.isGranted)
        set(\.tapState, tap.state)
        set(\.secureInput, InputPermission.secureInputActive)
        sensor.refreshStatus()
        set(\.sensorStatus, sensor.status)
        set(\.keysHeard, tap.eventsSeen)
        if audio.isRunning { set(\.audioInfo, audio.info) }
        let l = mixer.latencyStats()
        if l.count != queueLatency.count { queueLatency = l }
        set(\.launchAtLogin, LoginItem.isEnabled)
    }

    // MARK: Actions

    func requestPermission() {
        if !InputPermission.request() { openPrivacySettings() }
        refreshStatus()
    }

    func openPrivacySettings() { NSWorkspace.shared.open(InputPermission.settingsURL) }

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLoginError = LoginItem.set(on)
        launchAtLogin = LoginItem.isEnabled
    }

    func preview(profileID: String) {
        if !audio.isRunning { audio.start() }
        coordinator.apply(settings)
        coordinator.preview(profileID: profileID)
        if !settings.isAudible {
            previewStopWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.previewStopWork = nil
                if !self.settings.isAudible { self.audio.stop() }
            }
            previewStopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
        }
    }

    /// High-rate live sensor meter, only while the settings window is visible.
    func setMeterActive(_ active: Bool) {
        meterTimer?.invalidate(); meterTimer = nil
        guard active else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = ProcessClock.now()
                let floor = self.sensor.analyzer.noiseFloor
                let peak = self.sensor.analyzer.peak(from: now - 0.12, to: now) ?? 0
                self.meter.level = min(1, max(0, (peak - floor) / 0.15))
            }
        }
    }
}
