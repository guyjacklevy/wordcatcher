import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate // NSApplication holds its delegate weakly
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
