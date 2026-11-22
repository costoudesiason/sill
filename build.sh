#!/bin/bash
# Builds Sill.app into build/: SwiftPM's release binary in a bundle, signed.
#   ./build.sh          release build
#   ./build.sh run      build, then open it (quitting a running copy first)
#   ./build.sh ship     build, sign with a secure timestamp, notarise, staple,
#                       and zip to build/Sill.zip for a release
#                       (SILL_NOTARY_PROFILE names the notarytool profile)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Sill"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

APP="build/Sill.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sill"
# The MCP server agents run (AGENTS.md), beside the app's own binary.
mkdir -p "$APP/Contents/Helpers"
cp "$(dirname "$BIN")/sill-mcp" "$APP/Contents/Helpers/sill-mcp"
# The icon: an Icon Composer file, compiled the way Xcode would, so macOS
# renders its glass layers (Assets.car) with a flat fallback (AppIcon.icns).
xcrun actool --compile "$APP/Contents/Resources" --app-icon AppIcon --platform macosx \
  --minimum-deployment-target 26.0 --output-partial-info-plist "$(mktemp)" Resources/AppIcon.icon >/dev/null

VERSION="$(cat VERSION 2>/dev/null || echo 0.1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sill</string>
  <key>CFBundleDisplayName</key><string>Sill</string>
  <key>CFBundleIdentifier</key><string>com.iasoncostoudes.sill</string>
  <key>CFBundleExecutable</key><string>Sill</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSCameraUsageDescription</key><string>A website you're on wants to use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>A website you're on wants to use the microphone.</string>
  <key>NSLocationUsageDescription</key><string>A website you're on wants to know where you are.</string>
  <key>NSAppleEventsUsageDescription</key><string>Sill asks Safari for its open tabs when you import them.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>A website you're on wants to know where you are.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web site URL</string>
      <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
      <key>LSHandlerRank</key><string>Default</string>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Web page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>public.xhtml</string><string>com.apple.webarchive</string><string>public.svg-image</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# A stable signature keeps the keychain and the Passwords helper trusting
# the same app from build to build: Developer ID if there is one, else Apple
# Development, else ad hoc.
IDENTITY="${SILL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application[^"]*"' | tr -d '"' || true)}"
[ -z "$IDENTITY" ] && IDENTITY="$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)"
[ -z "$IDENTITY" ] && IDENTITY="-"
# With Apple's browser entitlement (passkeys for any site, and the right to
# run Apple's Passwords helper), the provisioning profile Apple issues for it
# goes next to this script as Sill.provisionprofile and is embedded here.
ENTITLEMENTS=Sill.entitlements
if [ -f Sill.provisionprofile ]; then
  cp Sill.provisionprofile "$APP/Contents/embedded.provisionprofile"
  PROFILE_PLIST="$(mktemp)"
  security cms -D -i Sill.provisionprofile > "$PROFILE_PLIST"
  TEAM="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
  APPID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
  BUNDLE_ID="${APPID#*.}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
  ENTITLEMENTS="$(mktemp).entitlements"
  cp Sill.entitlements "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APPID" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.web-browser.public-key-credential bool true" "$ENTITLEMENTS"
  echo "Embedding Sill.provisionprofile ($APPID): passkeys and Apple Passwords on"
fi
STAMP="--timestamp=none"
[ "${1:-}" = "ship" ] && STAMP="--timestamp"
codesign --force --options runtime $STAMP -s "$IDENTITY" "$APP/Contents/Helpers/sill-mcp" >/dev/null
codesign --force --options runtime --entitlements "$ENTITLEMENTS" $STAMP -s "$IDENTITY" "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1), signed: $IDENTITY)"

if [ "${1:-}" = "run" ]; then
  osascript -e 'tell application id "com.iasoncostoudes.sill" to quit' 2>/dev/null || true
  sleep 0.5
  open "$APP"
fi

if [ "${1:-}" = "ship" ]; then
  PROFILE="${SILL_NOTARY_PROFILE:-untitled-notary}"
  ZIP="build/Sill.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Notarising with profile $PROFILE…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl -a -vv "$APP" 2>&1 | head -3
  echo "Shipped $ZIP ($(du -h "$ZIP" | cut -f1))"
fi
