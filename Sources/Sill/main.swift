import AppKit

MainActor.assumeIsolated {
    Web.warm()
    // Before the app object exists: restored tabs find their icons decoded.
    Favicons.shared.preload()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
