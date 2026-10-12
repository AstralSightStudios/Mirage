#!/bin/sh
# Build qemu-system-arm from the qemu-miwear submodule for Mirage.
#
# Only what Mirage drives is enabled: TCG, the VNC server (the panel shows
# up in Mirage over VNC), pixman. No SDL/Cocoa/GTK windows, no network or
# crypto libraries, so the binary only needs glib and pixman.
#
# usage: Scripts/build-qemu.sh [extra configure flags]
#   QEMU_BUILD_DIR   build directory (default External/qemu-miwear/build)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=$ROOT/External/qemu-miwear
BUILD=${QEMU_BUILD_DIR:-$SRC/build}

if [ ! -f "$SRC/configure" ]; then
    echo "qemu-miwear submodule missing: git submodule update --init External/qemu-miwear" >&2
    exit 1
fi

# /usr/local may carry x86_64 Homebrew libraries that pkg-config would pick
export PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}

# Prefer Apple clang on macOS so cross-compilers in PATH (e.g. Android NDK) don't hijack host builds
if [ "$(uname -s)" = "Darwin" ]; then
    CC=${CC:-/usr/bin/clang}
    CXX=${CXX:-/usr/bin/clang++}
    OBJCC=${OBJCC:-$CC}
    export CC CXX OBJCC
fi

mkdir -p "$BUILD"
cd "$BUILD"
if [ ! -f build.ninja ]; then
    "$SRC/configure" \
        --target-list=arm-softmmu \
        --without-default-features \
        --enable-system --enable-tcg --enable-vnc --enable-pixman \
        --disable-werror --disable-debug-info --enable-strip \
        "$@"
fi
make -j"$(sysctl -n hw.ncpu)" qemu-system-arm
echo "built $BUILD/qemu-system-arm"
