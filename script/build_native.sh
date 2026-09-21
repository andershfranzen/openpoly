#!/usr/bin/env bash
# Builds and stages dist/OpenPoly.app: the SwiftUI menu bar app plus the bundled
# device/display helpers and their runtimes. The finished bundle needs no
# DisplayLink, Homebrew, Python, or separately installed Node runtime.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/macos"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="OpenPoly"
BUNDLE_ID="com.openpoly.OpenPoly"
MIN_SYSTEM_VERSION="14.0"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
HELPER_BUILD="$ROOT_DIR/build/p21ctl"
LIBUSB_DYLIB="libusb-1.0.0.dylib"
SIGN_IDENTITY="${OPENPOLY_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application:/ && length($2) == 40 {print $2}')"
  if [[ "$(printf '%s\n' "$IDENTITIES" | wc -w)" -eq 1 ]]; then
    SIGN_IDENTITY="$IDENTITIES"
  else
    SIGN_IDENTITY="-"
  fi
fi

# The Command Line Tools install is missing the SwiftUI macro plugin that the
# SDK's @State/@Bindable/@Environment macros need. Xcode ships it per platform,
# so point the compiler at it when it is not in the active toolchain.
swiftui_plugin_dir() {
  local candidate
  for candidate in \
    "${DEVELOPER_DIR:-}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
    "$(xcode-select -p 2>/dev/null || true)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
    "$(xcode-select -p 2>/dev/null || true)/usr/lib/swift/host/plugins"; do
    if [[ -n "$candidate" && -f "$candidate/libSwiftUIMacros.dylib" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

SWIFT_FLAGS=()
if PLUGIN_DIR="$(swiftui_plugin_dir)"; then
  SWIFT_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR")
fi

require_plugin() {
  if [[ ${#SWIFT_FLAGS[@]} -eq 0 ]]; then
    echo "build_native.sh: no SwiftUI macro plugin found; install Xcode or set DEVELOPER_DIR" >&2
    exit 1
  fi
}

run_swift() {
  swift "$@" --package-path "$PACKAGE_DIR" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
}

if [[ "${1:-}" == "--test" ]]; then
  shift
  require_plugin
  swift run --package-path "$PACKAGE_DIR" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} OpenPolyCheck "$@"
  exit 0
fi

if [[ ! -x "$HELPER_BUILD" ]]; then
  "$ROOT_DIR/script/build_and_run.sh" --build-only
fi

require_plugin
run_swift build
BIN_DIR="$(run_swift build --show-bin-path)"
"$ROOT_DIR/driver/macos/build.sh"

# A pinned official standalone runtime. Homebrew's node has many external dylib
# dependencies and cannot be copied into an app by itself.
[[ "$(uname -m)" == arm64 ]] || { echo "Display bundle currently targets Apple Silicon" >&2; exit 1; }
NODE_DIST="node-v24.19.0-darwin-arm64"
NODE_CACHE="$ROOT_DIR/build/display-runtime"
NODE_ARCHIVE="$NODE_CACHE/$NODE_DIST.tar.xz"
NODE_SHA="3f1cf157479c1480352083105e13faf9d008ede98e7e157746b6df940d197b94"
mkdir -p "$NODE_CACHE"
if [[ ! -f "$NODE_ARCHIVE" ]]; then
  curl -fL --retry 2 --max-time 120 "https://nodejs.org/dist/v24.19.0/$NODE_DIST.tar.xz" -o "$NODE_ARCHIVE.download"
  mv "$NODE_ARCHIVE.download" "$NODE_ARCHIVE"
fi
printf '%s  %s\n' "$NODE_SHA" "$NODE_ARCHIVE" | shasum -a 256 -c -
tar -xJf "$NODE_ARCHIVE" -C "$NODE_CACHE" "$NODE_DIST/bin/node" "$NODE_DIST/LICENSE"

USB_PREFIX="$(brew --prefix libusb)"
LIBUSB_SOURCE="$USB_PREFIX/lib/$LIBUSB_DYLIB"
if [[ ! -f "$LIBUSB_SOURCE" ]]; then
  echo "build_native.sh: $LIBUSB_SOURCE is missing; install libusb" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES/DisplayDriver" "$APP_RESOURCES/DisplaySource" "$APP_RESOURCES/Licenses"

cp "$BIN_DIR/$APP_NAME" "$APP_MACOS/$APP_NAME"
cp "$HELPER_BUILD" "$APP_MACOS/p21ctl"
cp "$LIBUSB_SOURCE" "$APP_FRAMEWORKS/$LIBUSB_DYLIB"
chmod +x "$APP_MACOS/$APP_NAME" "$APP_MACOS/p21ctl"
cp "$ROOT_DIR/build/p21-usb-bridge" "$ROOT_DIR/build/p21-desktop-host" "$APP_MACOS/"
cp "$NODE_CACHE/$NODE_DIST/bin/node" "$APP_MACOS/openpoly-display-runtime"
cp "$ROOT_DIR/driver/macos/"*.cjs "$APP_RESOURCES/DisplayDriver/"
ditto "$ROOT_DIR/driver" "$APP_RESOURCES/DisplaySource/driver"
cp "$ROOT_DIR/driver/licenses/"*.txt "$APP_RESOURCES/Licenses/"
cp "$ROOT_DIR/driver/macos/LICENSE.VirtualDisplayKit" "$APP_RESOURCES/Licenses/"
cp "$NODE_CACHE/$NODE_DIST/LICENSE" "$APP_RESOURCES/Licenses/Node-LICENSE.txt"

# Relative linkage: the helper finds libusb inside the bundle, never in Homebrew.
install_name_tool -id "@rpath/$LIBUSB_DYLIB" "$APP_FRAMEWORKS/$LIBUSB_DYLIB"
install_name_tool -change "$LIBUSB_SOURCE" "@executable_path/../Frameworks/$LIBUSB_DYLIB" "$APP_MACOS/p21ctl"
install_name_tool -change "$LIBUSB_SOURCE" "@executable_path/../Frameworks/$LIBUSB_DYLIB" "$APP_MACOS/p21-usb-bridge"

cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSCameraUsageDescription</key>
  <string>Show a live preview of your Poly Studio P21 while you adjust camera settings. No video is recorded.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Send your OpenPoly desktop to the connected P21 display. Screen images stay on this Mac and the USB display.</string>
  <key>NSHumanReadableCopyright</key>
  <string>Open source Poly Studio P21 controls.</string>
</dict>
</plist>
PLIST

# A unique installed Developer ID preserves the app's designated identity across
# rebuilds, including Screen Recording permission. Other machines use ad-hoc
# signing unless OPENPOLY_SIGN_IDENTITY explicitly selects a certificate.
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_FRAMEWORKS/$LIBUSB_DYLIB" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_MACOS/p21ctl" >/dev/null
for HELPER in p21-usb-bridge p21-desktop-host openpoly-display-runtime; do
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_MACOS/$HELPER" >/dev/null
done
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_BUNDLE" >/dev/null

echo "staged $APP_BUNDLE"
