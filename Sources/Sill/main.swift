import AppKit

MainActor.assumeIsolated {
    Web.warm()
    // Before the app object exists: restored tabs find their icons decoded.
    Favicons.shared.preload()
    // History read and made searchable in the background: the first visit
    // recorded and the first letter typed in ⌘T don't wait for it.
    History.preload()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
