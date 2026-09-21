#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$root/build"
usb_prefix=$(brew --prefix libusb)
clang -fobjc-arc -fblocks -mmacosx-version-min=13.0 -Wall -Wextra -Werror \
    "$root/driver/macos/p21-display-host.m" \
    "$root/driver/macos/p21-dl3.c" \
    -I"$usb_prefix/include/libusb-1.0" -L"$usb_prefix/lib" -lusb-1.0 \
    -framework Foundation -framework CoreGraphics -framework CoreMedia \
    -framework CoreVideo -framework ScreenCaptureKit \
    -o "$root/build/p21-display-host"
clang -std=c11 -mmacosx-version-min=13.0 -Wall -Wextra -Werror \
    "$root/driver/macos/p21-capture-dump.c" \
    "$root/driver/macos/p21-dl3-capture.c" \
    -o "$root/build/p21-capture-dump"
printf 'built %s\n' "$root/build/p21-display-host"
printf 'built %s\n' "$root/build/p21-capture-dump"
clang -std=c11 -O2 -mmacosx-version-min=13.0 -Wall -Wextra -Werror \
    "$root/driver/macos/p21-usb-bridge.c" "$root/driver/macos/p21-dl3.c" \
    -I"$usb_prefix/include/libusb-1.0" -L"$usb_prefix/lib" -lusb-1.0 \
    -o "$root/build/p21-usb-bridge"
clang -O2 -fobjc-arc -fblocks -mmacosx-version-min=13.0 -Wall -Wextra -Werror \
    "$root/driver/macos/p21-desktop-host.m" "$root/driver/macos/p21-haar.c" \
    -framework Foundation -framework CoreGraphics -framework CoreMedia \
    -framework CoreVideo -framework ScreenCaptureKit \
    -o "$root/build/p21-desktop-host"
printf 'built %s\n' "$root/build/p21-usb-bridge" "$root/build/p21-desktop-host"
