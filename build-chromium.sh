#!/bin/bash
# Builds Sill on Chromium: build/Sill Chromium.app, beside the WebKit Sill.
# The engine (CEF) comes from ~/sill-chromium/.cef; the app carries an APFS
# clone of its framework (no extra disk), and Chromium's five helper apps.
set -euo pipefail
cd "$(dirname "$0")"
CEF="$HOME/sill-chromium/.cef/cef"
WRAPPER="$HOME/sill-chromium/.cef/libcef_dll_wrapper.a"
# The engine, when it isn't there yet: Sill's own CEF build with every video
# format (ENGINE.md), kept as a release of this repository, and the small C++
# wrapper Sill links against, built from it.
ENGINE_TAG="engine-158.0.3-codecs"
ENGINE_FILE="cef_binary_158.0.3+g8c29be2+chromium-158.0.8127.18_macosarm64_minimal.tar.bz2"
ENGINE_SHA256="7a18cb9699e14a6f25a65d205eb8e290cdb035e9cb0a5910834100f27bc2d9a8"
if [ ! -d "$CEF/Release/Chromium Embedded Framework.framework" ]; then
  echo "Fetching the engine ($ENGINE_TAG)"
  TMP="$(mktemp -d)"
  if ! curl -fL --retry 3 ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} -o "$TMP/$ENGINE_FILE" \
      "https://github.com/costoudesiason/sill/releases/download/$ENGINE_TAG/${ENGINE_FILE//+/%2B}" \
     && ! { command -v gh >/dev/null && gh release download "$ENGINE_TAG" -R costoudesiason/sill -p "$ENGINE_FILE" -D "$TMP" --clobber; }; then
    rm -rf "$TMP"; echo "couldn't download $ENGINE_FILE (release $ENGINE_TAG)"; exit 1
  fi
  if [ "$(shasum -a 256 "$TMP/$ENGINE_FILE" | cut -d' ' -f1)" != "$ENGINE_SHA256" ]; then
    rm -rf "$TMP"; echo "$ENGINE_FILE isn't the engine this build expects (checksum differs)"; exit 1
  fi
  # Unpacked beside its place and moved in whole, so a half-unpacked engine is never taken for one.
  rm -rf "$CEF" "$CEF.part" "$WRAPPER"
  mkdir -p "$CEF.part"
  if ! tar -xjf "$TMP/$ENGINE_FILE" -C "$CEF.part" --strip-components=1; then
    rm -rf "$TMP" "$CEF.part"; echo "couldn't unpack $ENGINE_FILE"; exit 1
  fi
  mv "$CEF.part" "$CEF"
  rm -rf "$TMP"
fi
if [ ! -f "$WRAPPER" ]; then
  command -v cmake >/dev/null && command -v ninja >/dev/null || { echo "cmake and ninja are needed to build libcef_dll_wrapper (brew install cmake ninja)"; exit 1; }
  mkdir -p "$CEF/build"
  if ! (cd "$CEF/build" && cmake -G Ninja -DPROJECT_ARCH=arm64 -DCMAKE_BUILD_TYPE=Release .. && ninja libcef_dll_wrapper) > "$CEF/build/wrapper.log" 2>&1; then
    tail -20 "$CEF/build/wrapper.log"; echo "libcef_dll_wrapper build failed"; exit 1
  fi
  cp "$CEF/build/libcef_dll_wrapper/libcef_dll_wrapper.a" "$WRAPPER"
fi
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
  -I"$CEF" Tools/chromium-helper.mm -x none "$WRAPPER" -framework Cocoa -Wl,-dead_strip -o build/chromium-helper
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
# Google's Verified Media Path signature, which Netflix, Disney+, Prime Video and Max ask
# for. castLabs' EVS makes it and needs an account with them (pip install castlabs-evs,
# then python3 -m castlabs_evs.account signup), so it runs only when asked for. On macOS
# it has to come before code signing: it adds files that the code signature then seals.
if [ "${SILL_EVS_SIGN:-}" = "1" ]; then
  # sign-pkg only knows Electron's framework, so the binary and the place Chromium reads
  # its signature from (the framework's Resources) are named here.
  EVS_FW="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
  python3 -m castlabs_evs.vmp sign "$EVS_FW/Chromium Embedded Framework" "$EVS_FW/Resources/Chromium Embedded Framework.sig" || { echo "EVS signing failed (castlabs-evs installed and signed in?)"; exit 1; }
fi

IDENTITY="${SILL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application[^"]*"' | tr -d '"' || true)}"
[ -z "$IDENTITY" ] && IDENTITY="-"
codesign --force -s "$IDENTITY" "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" >/dev/null 2>&1
for HA in "$APP"/Contents/Frameworks/*Helper*.app; do codesign --force -s "$IDENTITY" "$HA" >/dev/null 2>&1; done
codesign --force -s "$IDENTITY" "$APP/Contents/Helpers/sill-mcp" >/dev/null 2>&1
codesign --force -s "$IDENTITY" "$APP" >/dev/null 2>&1
echo "Built $APP (signed: $IDENTITY)"
