# Sill on Chromium: what's left

Handoff list for the `chromium` branch. Read `AGENTS.md` and `ENGINE.md` first. Build with
`./build-chromium.sh` (produces `build/Sill Chromium.app`); the engine bridge is
`Sources/SillEngine/` (Objective-C++ over CEF 158, Alloy style), the app is `Sources/Sill/`.

House rules, from the owner:
- Look exactly like Apple's own macOS 27 apps; reuse what Sill already has (`GlassMenu`,
  the bar's glass capsules in `TopBar.swift`, `NSPopover` like Downloads, the palette's
  settings in `PaletteSettings.swift`) rather than new styles.
- Performance first: nothing that runs on a timer or per frame when idle.
- Animate only where asked; no extra flourishes.
- Check every change in the running app (screenshots), not only in code.

Order of value, highest first.

## 1. Extensions button and panel

A button on the right side of the bar, in the actions capsule with Downloads / New Tab /
Show All Tabs (`TopBar.swift`, `actionsGlass`), SF Symbol `puzzlepiece.extension`.

- Click opens a panel in the same glass popover style as Downloads
  (`BrowserWindowController.showDownloads`): each installed extension with its icon,
  name, version and an on/off switch, and a row to open its settings page.
- Today the only extension is uBlock Origin Lite, shipped in
  `Contents/Resources/Extensions` and loaded with `--load-extension` (see
  `InstallExtensions` in `SillEngine.mm`). Its ID is derived from its folder path
  (currently `flohjepcfceloadfphbicnlbebfnalch`).
- uBlock Origin Lite's own popup (`chrome-extension://<id>/popup.html`) sets the
  filtering mode for the current site. Try showing it inside the panel in an `SEWebView`.
  Its script asks `chrome.tabs.query({active: true, currentWindow: true})`, which may not
  know Alloy-style browsers; if it can't see the tab, give the panel a native per-site
  control instead (off / basic / optimal / complete), applied through the extension's
  messaging or its settings storage.
- Its dashboard (`chrome-extension://<id>/dashboard.html`) opens in a tab from the panel.
- Switching an extension off: CEF Alloy has no extension-management API; simplest is to
  leave it out of `--load-extension` and ask to relaunch, or remove its DNR rules at
  runtime if a supported way exists.
- Private windows use an in-memory request context (`gPrivateContext`) and get no
  extensions today; make uBlock Origin Lite run there too if CEF allows, otherwise say so
  in the panel.

## 2. Profile button

Beside the extensions button (or at the left of the actions capsule): the user's picture
from macOS (Contacts "Me" card / account picture), else initials, in a small circle.

- Click opens a `GlassMenu` (`GlassMenu.swift`): the name at the top, then New Private
  Window, History (⌘Y), Downloads, Passwords, Settings, and the profile list.
- Profiles = separate browsing data (cookies, history, sessions). In CEF each profile is a
  `CefRequestContext` with its own `cache_path` under
  `~/Library/Application Support/Sill Chromium/Profiles/<name>`; each window belongs to
  one profile and shows its picture in the button. "New Profile…" asks for a name. Keep a
  single default profile until the user makes another.
- Sill's own stores (history, session, downloads, site permissions) need a per-profile
  folder too.

## 3. Video formats and DRM

See `ENGINE.md`: build CEF with proprietary codecs and Widevine (must run on a Mac), swap
the engine in, allow the Widevine component, sign with castLabs EVS for Netflix & co.

Alternative the owner is also weighing: a hybrid. Tabs stay on Chromium; Netflix, Disney+,
Prime, Max, Apple TV, X/Instagram/Reddit video run on WKWebView (macOS has every codec and
FairPlay), chosen by a site list plus a fallback when a `<video>` fails. Copy that site's
cookies from Chromium to the WebKit store before switching so the user stays signed in;
convert uBlock Origin Lite's DNR rules into a WebKit content-rule list for those tabs.
`SillWebView` already mirrors WKWebView's API, which keeps this to a shared protocol
rather than a rewrite. Don't start this without the owner choosing it over the codec build.

## 4. Passkeys and iCloud Passwords

Waiting on Apple's `com.apple.developer.web-browser.public-key-credential` entitlement
(request 8AHXZ33V5U, App ID `com.iasoncostoudes.sill`). Chromium's WebAuthn UI for
Alloy-style browsers may be missing; plan: answer `navigator.credentials.create/get` in the
page with a script that forwards to Sill, which runs `ASAuthorizationPlatformPublicKeyCredentialProvider`
with the browser entitlement (client data hash from the page, origin taken from the
frame's real URL in the browser process, never from the page). Needs Developer ID signing
with the provisioning profile; ad-hoc signing with that entitlement won't launch.

## 5. Speed (Speedometer 3.1)

Baseline from the owner's run: score about 47.5 (iterations 48–50 once warm). Compare
with Dia/Chrome on the same Mac, then try: V8 flags, `--enable-features` that Chrome
ships on by default but CEF may not, renderer process priority/QoS for the helper apps,
and whether the CEF build has PGO (it should when built per `ENGINE.md` with
`--with-pgo-profiles`). Keep only what measurably helps across 5+ runs.

## 6. Smaller things already found

- Agent control on Chromium: `page.click` / `page.snapshot` fail because Sill's
  `AgentScript` isn't injected into Chromium pages. Inject it at document end (CEF has no
  user-script API in Alloy; do it from the render process handler in
  `Tools/chromium-helper.mm`, or by `Runtime.addScriptToEvaluateOnNewDocument` over the
  DevTools protocol).
- Sill's page scripts (`PageScripts.main`: media state, autofill, link hover) aren't
  injected either, same fix. Then `Tab.playingVideo` works, and
  `BrowserWindowController.isPlayingAudio` no longer has to answer "yes" for every page
  (which makes every tab switch run the picture-in-picture check).
- Camera, microphone and location prompts: route `CefPermissionHandler` to Sill's
  existing permission card (`Permissions.swift`).
- Downloads list UI on Chromium, `beforeunload` ("leave page?") via `mayClose`.
- Sleeping tabs restore by address only (no back/forward history).
- Developer ID signing and notarisation for `Sill Chromium.app` (today it's ad-hoc), and
  a release like WebKit Sill's `build.sh ship`.

## 7. WebKit scrolling experiment (low priority)

Measuring whether WebKit's private feature switches close the scroll gap to Chromium.
Harness: `/tmp/wktune` on the owner's Mac (a WKWebView that takes `on=`/`off=` feature
keys). Method agreed: confirm a switch takes effect (e.g. `requestAnimationFrame` rate
for `PreferPageRenderingUpdatesNear60FPSEnabled`), identical scripted scrolling, 20 runs
per setting, compare medians and the slowest 5% of frames, Sill Chromium on the same page
as the reference. Stop if the best setting doesn't get most of the way to Chromium.
