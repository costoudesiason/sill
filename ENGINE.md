# Building Sill's Chromium engine with every video format

Sill on Chromium (branch `chromium`) runs on CEF, the embeddable Chromium. The free
prebuilt CEF download is compiled **without** the licensed video formats, so today Sill
Chromium plays only VP9, AV1 and Opus. YouTube works; X, Instagram, Reddit, news sites,
most livestreams (H.264/AAC/HLS) and anything with DRM (Netflix, Disney+, Prime, Max,
Spotify) do not. Those formats can't be added to the prebuilt engine: they are switched
on when Chromium is compiled. This is the one-off job of compiling it.

## What the job is

Build **CEF 158.0.3 (Chromium 158.0.8127.18)**, the version Sill uses now, for **macOS
arm64**, with proprietary codecs and Widevine on, and hand back the minimal binary
distribution. Same version, so nothing else in Sill changes.

## Requirements

- **A Mac.** A Mac engine can only be built on macOS (Apple's SDK and toolchain). A
  Linux or Windows machine, including Linux cloud agents, cannot do it. A rented Mac
  (Namespace, GitHub's larger macOS runners, AWS EC2 Mac) can.
- Apple Silicon, 16 GB of memory or more, Xcode installed (`xcode-select -p`).
- About 50 GB free for the duration: Chromium source without history (~20 GB) plus one
  release build (~20–25 GB). Deleted afterwards (see the end).
- A few hours: 3–5 on a 10–16 core Apple Silicon Mac.

## Build

```sh
mkdir -p ~/cef-build && cd ~/cef-build
curl -fsSLO https://raw.githubusercontent.com/chromiumembedded/cef/master/tools/automate/automate-git.py

export GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome enable_widevine=true symbol_level=0 is_cfi=false"
export CEF_ARCHIVE_FORMAT=tar.bz2

python3 automate-git.py \
  --download-dir=$HOME/cef-build/download \
  --branch=8127 \
  --checkout=8c29be240971eebee960ac92114d3efccb5780ff \
  --arm64-build \
  --no-chromium-history \
  --with-pgo-profiles \
  --no-debug-build \
  --minimal-distrib \
  --distrib-subdir=sill
```

`8c29be24…` is the CEF commit of 158.0.3, the exact engine Sill ships today
(`include/cef_version.h`).

The result is
`~/cef-build/download/chromium/src/cef/binary_distrib/cef_binary_158.0.3+g8c29be2+chromium-158.0.8127.18_macosarm64_minimal.tar.bz2`
(a few hundred MB). **That file is the only thing to keep.** If the job runs on another
machine, publish it as a release asset on this repository (for example tag
`engine-158.0.3-codecs`).

## Put it into Sill

```sh
# Replace the engine Sill builds against
rm -rf ~/sill-chromium/.cef/cef
mkdir -p ~/sill-chromium/.cef/cef
tar -xjf cef_binary_*_macosarm64_minimal.tar.bz2 -C ~/sill-chromium/.cef/cef --strip-components=1

# Rebuild the small C++ wrapper Sill links against
cd ~/sill-chromium/.cef/cef && mkdir -p build && cd build
cmake -G Ninja -DPROJECT_ARCH=arm64 -DCMAKE_BUILD_TYPE=Release ..
ninja libcef_dll_wrapper
cp libcef_dll_wrapper/libcef_dll_wrapper.a ~/sill-chromium/.cef/libcef_dll_wrapper.a

# Build Sill as usual
cd ~/sill && ./build-chromium.sh
```

## Widevine (DRM)

- Chromium downloads Google's Widevine module at runtime through its component
  updater. Sill currently turns that updater off (`disable-component-update` in
  `Sources/SillEngine/SillEngine.mm`, `SEApp::OnBeforeCommandLineProcessing`); it has to
  allow the Widevine component.
- Netflix, Disney+, Prime Video and Max also require the app to be signed through
  Google's Verified Media Path. castLabs' EVS service does this for free
  (`pip install castlabs-evs`, then `python3 -m castlabs_evs.vmp sign <framework binary> <signature>`). On
  macOS this has to run before Sill's own code signing. `SILL_EVS_SIGN=1
  ./build-chromium.sh` does it at the right point; it needs a castLabs account.

## Check it worked

In any page in Sill Chromium (or through the agent socket's `page.eval`):

```js
const M = t => MediaSource.isTypeSupported(t);
({ h264: M('video/mp4; codecs="avc1.42E01E"'), aac: M('audio/mp4; codecs="mp4a.40.2"'),
   hevc: M('video/mp4; codecs="hvc1.1.6.L93.B0"'),
   widevine: await navigator.requestMediaKeySystemAccess('com.widevine.alpha',
     [{ videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }] }]).then(() => true, e => String(e)) })
```

Today all four are false. With the new engine, h264, aac and hevc should be true, and
widevine true once the component has downloaded.

## Afterwards

Delete `~/cef-build` (20–50 GB). Sill only needs the extracted engine in
`~/sill-chromium/.cef`. The build is only needed again to move to a newer Chromium
for security fixes.
