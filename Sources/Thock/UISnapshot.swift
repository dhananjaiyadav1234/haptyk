import AppKit
import SwiftUI

/// `Thock --snapshot <dir>` renders each Settings tab to a PNG using the real views (for visual review).
@MainActor
enum UISnapshot {
    static func run(directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppController.shared
        let nav = SettingsNavigation.shared
        let host = NSHostingController(rootView: SettingsView().environmentObject(controller).environmentObject(nav))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 560, height: 520))
        window.orderFrontRegardless()
        for (name, tab) in [("general", SettingsTab.general), ("sounds", .sounds), ("intensity", .intensity), ("permissions", .permissions), ("about", .about)] {
            nav.tab = tab
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
            }
        }
    }
}
