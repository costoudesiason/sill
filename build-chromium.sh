#!/bin/bash
# Builds Sill on Chromium: build/Sill Chromium.app, beside the WebKit Sill.
# The engine (CEF) comes from ~/sill-chromium/.cef; the app carries an APFS
# clone of its framework (no extra disk), and Chromium's five helper apps.
set -euo pipefail
cd "$(dirname "$0")"
CEF="$HOME/sill-chromium/.cef/cef"
if ! swift build -c release --arch arm64 > build.log 2>&1; then grep -E "error" build.log | head -20; echo "build failed"; exit 1; fi
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Sill"
APP="build/Sill Chromium.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/Sill"
strip -rSTx "$APP/Contents/MacOS/Sill"
cp "$(dirname "$BIN")/sill-mcp" "$APP/Contents/Helpers/"
# The icon and Info.plist as the WebKit build makes them, then made its own.
[ -d build/Sill.app ] || ./build.sh >/dev/null
cp build/Sill.app/Contents/Resources/AppIcon.icns build/Sill.app/Contents/Resources/Assets.car "$APP/Contents/Resources/"
cp build/Sill.app/Contents/Info.plist "$APP/Contents/Info.plist"
P=/usr/libexec/PlistBuddy
$P -c "Set :CFBundleIdentifier com.iasoncostoudes.sill.chromium" "$APP/Contents/Info.plist"
$P -c "Set :NSPrincipalClass SEApplication" "$APP/Contents/Info.plist"
cp -Rc "$CEF/Release/Chromium Embedded Framework.framework" "$APP/Contents/Frameworks/"
# Extensions that come with Sill: uBlock Origin Lite (~/sill-chromium/ubol-<version>, the newest).
UBOL=$(ls -d "$HOME"/sill-chromium/ubol-2* 2>/dev/null | sort | tail -1)
if [ -n "$UBOL" ]; then
  mkdir -p "$APP/Contents/Resources/Extensions"
  rm -rf "$APP/Contents/Resources/Extensions/uBlock Origin Lite"
  cp -Rc "$UBOL" "$APP/Contents/Resources/Extensions/uBlock Origin Lite"
fi
clang++ -x objective-c++ -arch arm64 -mmacosx-version-min=26.0 -std=c++20 -O2 -fobjc-arc -fno-rtti -fno-exceptions \
  -I"$CEF" Tools/chromium-helper.mm -x none "$HOME/sill-chromium/.cef/libcef_dll_wrapper.a" -framework Cocoa -Wl,-dead_strip -o build/chromium-helper
for kind in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  H="Sill Helper$kind"
  HA="$APP/Contents/Frameworks/$H.app"
  mkdir -p "$HA/Contents/MacOS"
  cp build/chromium-helper "$HA/Contents/MacOS/$H"
  suffix=$(echo "$kind" | tr -d ' ()' | tr 'A-Z' 'a-z')
  cat > "$HA/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.iasoncostoudes.sill.chromium.helper${suffix:+.$suffix}</string>
<key>CFBundleName</key><string>$H</string><key>CFBundleExecutable</key><string>$H</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string><key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
P
done
rm -f build/chromium-helper
# Signed as the same app from build to build (Developer ID if there is one),
# inside out: the engine, its helpers, the agent tool, then the app. macOS
# then knows it across builds: the Keychain's "always allow" holds, and
# saved passwords open without asking again.
IDENTITY="${SILL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application[^"]*"' | tr -d '"' || true)}"
[ -z "$IDENTITY" ] && IDENTITY="-"
codesign --force -s "$IDENTITY" "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" >/dev/null 2>&1
for HA in "$APP"/Contents/Frameworks/*Helper*.app; do codesign --force -s "$IDENTITY" "$HA" >/dev/null 2>&1; done
codesign --force -s "$IDENTITY" "$APP/Contents/Helpers/sill-mcp" >/dev/null 2>&1
codesign --force -s "$IDENTITY" "$APP" >/dev/null 2>&1
echo "Built $APP (signed: $IDENTITY)"
