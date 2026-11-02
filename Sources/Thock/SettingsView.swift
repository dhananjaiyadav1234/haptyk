import SwiftUI
import ThockCore

enum SettingsTab: Hashable { case general, sounds, intensity, permissions, about }

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        TabView(selection: $nav.tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            SoundsTab().tabItem { Label("Sounds", systemImage: "speaker.wave.2") }.tag(SettingsTab.sounds)
            IntensityTab().tabItem { Label("Intensity", systemImage: "waveform.path") }.tag(SettingsTab.intensity)
            PermissionsTab().tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(SettingsTab.permissions)
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
        .frame(width: 560, height: 520)
    }
}

// MARK: General

struct GeneralTab: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        Form {
            Section {
                Toggle("Keyboard sounds", isOn: $c.settings.enabled)
                Toggle("Mute", isOn: $c.settings.muted).disabled(!c.settings.enabled)
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $c.settings.volume, in: 0...1).accessibilityLabel("Volume")
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    Text("\(Int(c.settings.volume * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            } header: { Text("Sound") }

            Section {
                Toggle("Play key-release sounds", isOn: $c.settings.keyReleaseSounds)
                HStack {
                    Text("Stereo width")
                    Slider(value: $c.settings.stereoWidth, in: 0...1)
                }
            } header: { Text("Feel") }
            footer: { Text("Stereo width pans each key slightly left or right according to its place on the keyboard.") }

            Section {
                Toggle("Open Thock at login", isOn: Binding(get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
                if let e = c.launchAtLoginError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
                if LoginItem.needsApproval {
                    Text("Approve Thock in System Settings → General → Login Items.").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Startup") }
        }
        .formStyle(.grouped)
    }
}

// MARK: Sounds

struct SoundsTab: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a switch sound. Click the speaker to hear it.").font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 8)
            List {
                ForEach(SoundProfiles.all) { p in
                    HStack(spacing: 12) {
                        Image(systemName: p.id == c.settings.profileID ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(p.id == c.settings.profileID ? Color.accentColor : .secondary)
                            .imageScale(.large)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.headline)
                            Text(p.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button { c.preview(profileID: p.id) } label: { Image(systemName: "play.circle.fill").imageScale(.large) }
                            .buttonStyle(.borderless)
                            .help("Preview \(p.name)")
                            .accessibilityLabel("Preview \(p.name)")
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { c.settings.profileID = p.id; c.preview(profileID: p.id) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(p.id == c.settings.profileID ? [.isSelected, .isButton] : .isButton)
                }
            }
            .listStyle(.inset)
        }
    }
}

// MARK: Intensity

struct MeterBar: View {
    @ObservedObject var meter: SensorMeter
    var body: some View { ProgressView(value: meter.level).progressViewStyle(.linear) }
}

struct IntensityTab: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        Form {
            Section {
                Toggle("Respond to typing intensity", isOn: $c.settings.sensorEnabled)
                HStack {
                    Text("Sensitivity")
                    Slider(value: $c.settings.sensitivity, in: 0...1)
                        .disabled(!c.settings.sensorEnabled)
                    Text("\(Int(c.settings.sensitivity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            } footer: {
                Text("Harder keystrokes play louder and slightly lower; lighter keystrokes play softer. At 0% every key sounds the same strength.")
            }

            Section {
                LabeledContent("Source") { Text(sourceText) }
                LabeledContent("Status") { statusView }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live vibration").font(.caption).foregroundStyle(.secondary)
                    MeterBar(meter: c.meter)
                    Text("Tap the palm rest or the desk to see the bar move. If it stays flat while you type, this Mac's sensor is not picking up your keystrokes and Thock uses typing rhythm instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Built-in accelerometer") }
        }
        .formStyle(.grouped)
        .onAppear { c.setMeterActive(true) }
        .onDisappear { c.setMeterActive(false) }
    }

    private var sourceText: String {
        switch c.sensorStatus {
        case .streaming: return "Accelerometer"
        default: return c.settings.sensorEnabled ? "Typing rhythm (fallback)" : "Off"
        }
    }

    @ViewBuilder private var statusView: some View {
        switch c.sensorStatus {
        case .streaming(let hz): Label("Streaming at \(Int(hz.rounded())) Hz", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .unsupported: Label("Not available on this Mac", systemImage: "xmark.circle").foregroundStyle(.secondary)
        case .noData: Label("No data received", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .stopped: Text(c.settings.sensorEnabled ? "Waiting for the app to be active" : "Off").foregroundStyle(.secondary)
        }
    }
}

// MARK: Permissions

struct PermissionsTab: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        Form {
            Section {
                LabeledContent("Input Monitoring") {
                    if c.inputGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not granted", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                LabeledContent("Keyboard listener") { Text(listenerText) }
                LabeledContent("Secure input") {
                    if c.secureInput { Text("On — sounds pause in password fields").foregroundStyle(.orange) }
                    else { Text("Off").foregroundStyle(.secondary) }
                }
                if !c.inputGranted {
                    HStack {
                        Button("Request Access") { c.requestPermission() }
                        Button("Open System Settings") { c.openPrivacySettings() }
                    }
                }
            } header: { Text("Status") }

            Section {
                Text("Thock needs **Input Monitoring** so macOS lets it know *when* a key is pressed anywhere on your Mac. Without it, no sounds can play.")
                Text("1. Click **Request Access** (or open System Settings → Privacy & Security → Input Monitoring).\n2. Switch **Thock** on. If macOS asks, choose Quit & Reopen.\n3. Thock detects the change automatically within a second.")
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text("How to enable") }

            Section {
                Label("Only the physical key code is used to pick a sound. Typed characters are never read.", systemImage: "eye.slash")
                Label("Nothing is stored or logged, and the app makes no network connections.", systemImage: "network.slash")
                Label("macOS blocks all keyboard listeners during secure input (password fields), so no sound plays there.", systemImage: "key.fill")
            } header: { Text("Privacy") }
        }
        .formStyle(.grouped)
    }

    private var listenerText: String {
        switch c.tapState {
        case .running: return "Running"
        case .needsPermission: return "Waiting for permission"
        case .failed: return "Failed — try toggling the permission"
        case .stopped: return c.settings.isAudible ? "Starting…" : "Stopped (sounds off)"
        }
    }
}

// MARK: About

struct AboutTab: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "keyboard.fill").font(.system(size: 34)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text("Thock").font(.title2.bold())
                        Text("Version \(version) · Local, free, no network").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent("Output device") { Text(c.audioInfo.deviceName) }
                LabeledContent("Sample rate") { Text(c.audioInfo.sampleRate > 0 ? "\(Int(c.audioInfo.sampleRate)) Hz" : "—") }
                LabeledContent("I/O buffer") {
                    Text(bufferText)
                }
                LabeledContent("Estimated output latency") {
                    Text(c.audioInfo.estimatedOutputLatencyMs > 0 ? String(format: "%.1f ms", c.audioInfo.estimatedOutputLatencyMs) : "—")
                }
                LabeledContent("Keystroke → audio queue") {
                    Text(c.queueLatency.count > 0
                         ? String(format: "avg %.2f ms, max %.2f ms (%d sounds)", c.queueLatency.mean * 1000, c.queueLatency.max * 1000, c.queueLatency.count) : "—")
                }
                LabeledContent("Key events heard") { Text("\(c.keysHeard)") }
            } header: { Text("Diagnostics (measured, not estimated unless noted)") }
        }
        .formStyle(.grouped)
    }

    private var bufferText: String {
        let i = c.audioInfo
        guard i.bufferFrames > 0 else { return "—" }
        let ms = Double(i.bufferFrames) / max(i.sampleRate, 1) * 1000
        return "\(i.bufferFrames) frames (\(String(format: "%.1f", ms)) ms)"
    }

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}
