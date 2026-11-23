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

## Done since this list was written

- Extensions button and panel (`Extensions.swift`): uBlock Origin Lite's per-site mode
  set natively through its `getFilteringMode`/`setFilteringMode` messages (its own popup
  can't see Sill's tabs).
- Profile button and menu (your Mac account picture).
- Sill's page script and the agents' script run in Chromium pages (handed over at page
  creation, run by the helper at document start; messages via `__sillPost`). Agent
  snapshots/clicks work. Gap: on Chromium they share the page's JavaScript world, where
  WebKit had a private one.
- Passwords (`SavedPasswords.swift`): Keychain storage, glass fill menu, save/update card
  after a sign-in, Import from Dia in the profile menu. Chromium's own autofill is off.
  Still to do: a place in Sill to see, edit and delete saved passwords (today they're in
  Keychain Access as "Sill: <site>"), and "never for this site".

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

- `Tab.playingVideo` now comes from the page script on Chromium, so
  `BrowserWindowController.isPlayingAudio` can stop answering "yes" for every page
  (it makes every tab switch run the picture-in-picture check).
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
