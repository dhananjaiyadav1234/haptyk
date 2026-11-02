import AppKit
import SwiftUI
import Combine
import ThockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let controller = AppController.shared
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var volumeSlider: NSSlider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshStatusIcon()

        controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshStatusIcon() } }
            .store(in: &cancellables)

        controller.start()

        // First run, or permission still missing: guide the user straight to the explanation.
        if !InputPermission.isGranted { showSettings(tab: .permissions) }
    }

    func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(tab: nil); return true
    }

    // MARK: Status item

    private func refreshStatusIcon() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Thock")
        image?.isTemplate = true
        button.image = image
        let needsAttention = controller.settings.isAudible && !controller.inputGranted
        button.title = needsAttention ? "!" : ""
        button.imagePosition = needsAttention ? .imageLeading : .imageOnly
        button.appearsDisabled = !controller.settings.isAudible
        button.toolTip = statusLine()
    }

    private func statusLine() -> String {
        let s = controller.settings
        if !s.enabled { return "Thock is off" }
        if s.muted { return "Thock is muted" }
        if !controller.inputGranted { return "Needs Input Monitoring permission" }
        if controller.secureInput { return "Secure input is on — sounds pause in password fields" }
        switch controller.tapState {
        case .running: return "Listening · \(SoundProfiles.profile(id: s.profileID)?.name ?? "")"
        case .failed: return "Keyboard listener failed — see Settings"
        default: return "Starting…"
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = controller.settings

        let header = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if !controller.inputGranted {
            let fix = NSMenuItem(title: "Grant Input Monitoring Access…", action: #selector(grantAccess), keyEquivalent: "")
            fix.target = self; fix.isEnabled = true
            menu.addItem(fix)
        }
        menu.addItem(.separator())

        let enabled = NSMenuItem(title: "Keyboard Sounds", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self; enabled.isEnabled = true; enabled.state = s.enabled ? .on : .off
        menu.addItem(enabled)

        let mute = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "m")
        mute.keyEquivalentModifierMask = [.command]
        mute.target = self; mute.isEnabled = true; mute.state = s.muted ? .on : .off
        menu.addItem(mute)

        menu.addItem(volumeItem(value: s.volume))

        menu.addItem(.separator())
        let profiles = NSMenuItem(title: "Sound Profile", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for p in SoundProfiles.all {
            let item = NSMenuItem(title: p.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self; item.isEnabled = true
            item.representedObject = p.id
            item.state = p.id == s.profileID ? .on : .off
            sub.addItem(item)
        }
        profiles.submenu = sub; profiles.isEnabled = true
        menu.addItem(profiles)

        let preview = NSMenuItem(title: "Preview Sound", action: #selector(previewCurrent), keyEquivalent: "")
        preview.target = self; preview.isEnabled = true
        menu.addItem(preview)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self; settingsItem.isEnabled = true
        menu.addItem(settingsItem)
        let quit = NSMenuItem(title: "Quit Thock", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; quit.isEnabled = true
        menu.addItem(quit)
    }

    private func volumeItem(value: Double) -> NSMenuItem {
        let item = NSMenuItem()
        let width: CGFloat = 220
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        let low = NSImageView(frame: NSRect(x: 14, y: 6, width: 16, height: 18))
        low.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Quieter")
        low.contentTintColor = .secondaryLabelColor
        let high = NSImageView(frame: NSRect(x: width - 32, y: 6, width: 20, height: 18))
        high.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Louder")
        high.contentTintColor = .secondaryLabelColor
        let slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged(_:)))
        slider.frame = NSRect(x: 36, y: 5, width: width - 74, height: 20)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Volume")
        [low, high, slider].forEach(view.addSubview)
        item.view = view
        volumeSlider = slider
        return item
    }

    @objc private func volumeChanged(_ sender: NSSlider) { controller.settings.volume = sender.doubleValue }
    @objc private func toggleEnabled() { controller.settings.enabled.toggle() }
    @objc private func toggleMute() { controller.settings.muted.toggle() }
    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        controller.settings.profileID = id
        controller.preview(profileID: id)
    }
    @objc private func previewCurrent() { controller.preview(profileID: controller.settings.profileID) }
    @objc private func grantAccess() { showSettings(tab: .permissions); controller.requestPermission() }
    @objc private func openSettings() { showSettings(tab: nil) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Settings window

    func showSettings(tab: SettingsTab?) {
        if let tab { SettingsNavigation.shared.tab = tab }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(controller).environmentObject(SettingsNavigation.shared))
            let window = NSWindow(contentViewController: host)
            window.title = "Thock Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 560, height: 520))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        controller.setMeterActive(false)
        NSApp.setActivationPolicy(.accessory)
    }
}
