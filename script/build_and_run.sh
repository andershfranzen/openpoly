#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
USB_PREFIX="$(brew --prefix libusb)"
cc -std=c11 -Wall -Wextra -Werror -O2 src/*.c \
  -I"$USB_PREFIX/include/libusb-1.0" -L"$USB_PREFIX/lib" -lusb-1.0 \
  -framework CoreGraphics -framework CoreAudio -framework CoreFoundation -o build/p21ctl

APP_BUNDLE="dist/OpenPoly.app"

build_app() {
  ./script/build_native.sh
}

launch_app() {
  build_app
  pkill -x OpenPoly >/dev/null 2>&1 || true
  if [[ $# -gt 0 ]]; then
    /usr/bin/open -n "$APP_BUNDLE" --args "$@"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

case "${1:-}" in
  "")
    # Default Run: build the native menu bar app and launch it.
    launch_app
    ;;
  --build-only)
    # CLI-only build, unchanged: offline checks and the CLI rely on this.
    exit 0
    ;;
  --app-only|--build-app-only)
    build_app
    ;;
  --test)
    shift
    exec ./script/build_native.sh --test "$@"
    ;;
  --debug)
    shift
    exec lldb -- build/p21ctl "$@"
    ;;
  --logs)
    shift
    launch_app "$@"
    exec /usr/bin/log stream --info --style compact --predicate 'process == "OpenPoly"'
    ;;
  --verify)
    shift
    launch_app "$@"
    sleep 2
    pgrep -x OpenPoly >/dev/null
    ;;
  *)
    # Explicit CLI arguments keep driving the CLI.
    exec build/p21ctl "$@"
    ;;
esac
