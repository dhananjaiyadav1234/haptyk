import AppKit

// Command-line diagnostics share the app binary so they can run without the GUI.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--snapshot" {
    MainActor.assumeIsolated { UISnapshot.run(directory: CommandLine.arguments[2]) }
    exit(0)
}
if CommandLine.arguments.count > 1, Diagnostics.run(arguments: Array(CommandLine.arguments.dropFirst())) {
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
