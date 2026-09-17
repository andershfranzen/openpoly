#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
USB_PREFIX="$(brew --prefix libusb)"
cc -std=c11 -Wall -Wextra -Werror -O2 src/*.c \
  -I"$USB_PREFIX/include/libusb-1.0" -L"$USB_PREFIX/lib" -lusb-1.0 \
  -framework CoreGraphics -framework CoreAudio -framework CoreFoundation -o build/p21ctl
if [[ "${1:-}" == --build-only ]]; then exit 0; fi
if [[ "${1:-}" == --debug ]]; then shift; exec lldb -- build/p21ctl "$@"; fi
exec build/p21ctl "$@"
