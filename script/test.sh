#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./script/build_and_run.sh --build-only
./driver/macos/build.sh
USB_PREFIX="$(brew --prefix libusb)"
cc -std=c11 -Wall -Wextra -Werror tests/dl3.c driver/macos/p21-dl3.c \
  -I"$USB_PREFIX/include/libusb-1.0" -L"$USB_PREFIX/lib" -lusb-1.0 -o build/check-dl3
build/check-dl3
cc -std=c11 -Wall -Wextra -Werror tests/dl3_capture.c \
  driver/macos/p21-dl3-capture.c -o build/check-dl3-capture
build/check-dl3-capture
cc -std=c11 -O2 -Wall -Wextra -Werror -fsanitize=address,undefined \
  tests/haar.c driver/macos/p21-haar.c -o build/test-haar
node tests/dl3_session.cjs
node tests/p21_video.cjs
node tests/p21_display_settings.cjs
cc -std=c11 -Wall -Wextra -Werror tests/check.c src/usb.c \
  -I"$USB_PREFIX/include/libusb-1.0" -L"$USB_PREFIX/lib" -lusb-1.0 -o build/check
build/check
cc -std=c11 -Wall -Wextra -Werror tests/hid.c \
  -I"$USB_PREFIX/include/libusb-1.0" -o build/check-hid
build/check-hid
cc -std=c11 -Wall -Wextra -Werror tests/bar.c src/usb.c \
  -I"$USB_PREFIX/include/libusb-1.0" -L"$USB_PREFIX/lib" -lusb-1.0 -o build/check-bar
build/check-bar
cc -std=c11 -Wall -Wextra -Werror tests/sides.c src/usb.c \
  -I"$USB_PREFIX/include/libusb-1.0" -L"$USB_PREFIX/lib" -lusb-1.0 -o build/check-sides
build/check-sides
cc -std=c11 -Wall -Wextra -Werror tests/camera.c \
  -I"$USB_PREFIX/include/libusb-1.0" -L"$USB_PREFIX/lib" -lusb-1.0 -o build/check-camera
build/check-camera
for args in 'unknown' 'camera nonexistent' 'camera zoom 10 20' 'hid unknown' 'hid mute-indicator invalid' 'audio unknown' 'screen mode -1' 'screen modes extra' 'lights left 101' 'lights left -1' 'lights manual 1' 'lights list extra' 'lights sides 101 0' 'lights sides 0' 'lights cycle 0' 'lights cycle 30 0' 'lights cycle 30 3601' 'lights cycle 30 30 extra'; do
  if build/p21ctl $args > /dev/null 2>&1; then
    echo "Unexpected acceptance: $args" >&2; exit 1
  fi
done
echo 'CLI rejects unknown commands and wrong argument counts: passed'
