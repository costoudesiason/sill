# Sill

A small, fast web browser for macOS 27, built on WebKit and Apple's own
components: Liquid Glass where Apple puts it (the toolbar, the ⌘T palette,
controls), plain content everywhere else.

```
./build.sh        # build/Sill.app (release, signed)
./build.sh run    # build, quit the running copy, open the new one
```

## What it does

- **Horizontal tabs in the toolbar.** The tab in front sits in one piece of
  glass that slides when you switch. Drag to reorder; middle-click or ⌘W to
  close; closing with the mouse keeps widths still so the next × lands under
  the pointer. Restored tabs cost nothing until clicked; tabs idle for 45
  minutes give their memory back (never one playing sound or using the
  camera).
- **⌘T / ⌘L palette.** One glass panel: open tabs, history (frecency),
  inline address completion, search suggestions. ↩ opens, ⌘K shows actions,
  Tab accepts a completion, Esc backs out. ⌘L (or a click on the tab in
  front) edits the current address.
- **Picture in picture.** Leave a tab playing a video and macOS's own
  picture in picture window takes it; come back (or press its return
  button) and it goes back into the page.
- **Ads and trackers blocked.** A short, hand-written WebKit content rule
  list (about 44 advertising and analytics companies, blocked only as third
  parties, plus the empty boxes they leave). Compiled once and cached. No
  third-party filter list is bundled. YouTube is left alone; right-click a
  tab to turn it off for one site.
- **Everything else a browser needs:** back/forward swipes, find (⌘F),
  zoom, downloads to ~/Downloads, private windows (⇧⌘N, nothing written),
  reopen closed tab (⇧⌘T), ⌘1–9, ⌃Tab, Web Inspector (⌥⌘I), default browser.

## iCloud Passwords and passkeys

Sill speaks the same protocol as Apple's iCloud Passwords extension for
Chrome, through Apple's own `PasswordManagerBrowserExtensionHelper`. On
macOS 27 the system only lets **browsers Apple has approved** start that
helper (it's killed with a launch-constraint violation otherwise), and the
same approval is what lets a browser use passkeys for any site.

To turn both on:

1. As Account Holder of an organisation developer account, request the
   *Web Browser Public Key Credential* entitlement:
   <https://developer.apple.com/contact/request/macos-browsers-passkeys/>
2. Once granted, make a Developer ID provisioning profile for Sill's bundle
   id with that capability, save it as `Sill.provisionprofile` next to
   `build.sh`, and run `./build.sh`. The script embeds it and signs with the
   entitlement.
3. Settings › Passwords › Connect, then type the six-digit code macOS shows.
   (The pairing lasts until Sill quits, as with Apple's Chrome extension.)

## Credits

The Apple Passwords protocol (SRP pairing, sealed messages) and the native
messaging pipe are adapted from [Search](https://github.com/driceroland/Search)
by Office Commun, MIT License, as are the ad and tracker rules in
`Shield.swift`. About twenty of their generic ad-slot names come from
EasyList's hiding rules. See NOTICE.

## License

MIT. See LICENSE and NOTICE.
