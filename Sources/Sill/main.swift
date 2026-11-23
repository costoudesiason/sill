import AppKit

MainActor.assumeIsolated {
    // The app object Chromium needs, before AppKit makes its own.
    _ = SEApplication.shared
    // Before the app object exists: restored tabs find their icons decoded.
    Favicons.shared.preload()
    // History read and made searchable in the background: the first visit
    // recorded and the first letter typed in ⌘T don't wait for it.
    History.preload()
    // Chromium, with its profile (cookies, caches) beside Sill's own files.
    // Sill's page script and the agents' script, in every page.
    SEEngine.setPageScripts([PageScripts.main, AgentScript.source])
    guard SEEngine.start(withProfile: Places.support.path) else {
        NSLog("Sill: Chromium didn't start")
        exit(1)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { SEEngine.run() }
    SEEngine.shutdown()
}
