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
  codesign -s - --force "$HA" >/dev/null 2>&1
done
rm -f build/chromium-helper
codesign -s - --force "$APP/Contents/Helpers/sill-mcp" >/dev/null 2>&1
codesign -s - --force "$APP/Contents/MacOS/Sill" >/dev/null 2>&1
echo "Built $APP"
