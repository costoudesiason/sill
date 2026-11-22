# Apple request: Web Browser Public Key Credential entitlement (macOS)

Form: https://developer.apple.com/contact/request/macos-browsers-passkeys/
(Account Holder of the developer account must submit it.)

Use these answers; adjust anything Apple's form asks that isn't here.

**App name:** Sill

**Bundle ID:** com.iasoncostoudes.sill

**Team ID:** B6WAZ4WYX7

**Platform:** macOS 27

**What the app is:**
Sill is a general-purpose web browser for macOS built on WebKit (WKWebView).
People use it as their default browser: it registers for the http and https
URL schemes and opens links from other apps directly.

**How it meets the browser criteria:**
- Declares the http and https schemes in its Info.plist and can be set as the
  default browser in System Settings.
- On launch it shows a field for entering a URL or search terms (the ⌘T
  palette), with search via the user's chosen engine (Google, DuckDuckGo,
  Bing, Kagi, Ecosia).
- Navigates directly to the requested URL and renders the site's own content
  unmodified, with no redirection or injected content.
- Shows WebKit's Safe Browsing warning for fraudulent sites.

**Why it needs the entitlement:**
So people can sign in to any website with their passkeys and security keys,
as they can in Safari, using the system's passkey sheet (iCloud Keychain,
nearby iPhone, or a security key). Sill also offers the user's iCloud Keychain
passwords under sign-in fields, through Apple's Passwords browser helper.

**Distribution:** Developer ID, outside the Mac App Store.
