#!/bin/sh
# Build the C smoke test against the release static library, linking exactly
# what a Swift/Xcode target has to link.
set -e
cd "$(dirname "$0")/.."
cargo build --release
clang -O1 -Wall -Wextra -Iinclude examples/smoke.c target/release/libmirage_astrobox.a \
    -framework CoreAudio -framework Security -framework IOKit -framework IOBluetooth \
    -framework CoreBluetooth -framework WebKit -framework ApplicationServices \
    -framework CoreGraphics -framework Carbon -framework CoreVideo \
    -framework CoreFoundation -framework AppKit -framework Foundation \
    -liconv -lobjc -lc -lm -Wl,-dead_strip \
    -o target/smoke
echo "built target/smoke"
