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
FINAL_BUILD=

if [ ! -f "$SRC/configure" ]; then
    echo "qemu-miwear submodule missing: git submodule update --init External/qemu-miwear" >&2
    exit 1
fi

# QEMU's configure rejects source or build paths containing whitespace or
# colons. Mirage is often checked out below a volume or folder with a space in
# its name, so mirror the source into a clean temporary directory and build
# there, then copy the binary back next to the submodule.
has_unsafe_path() {
    case "$1" in
        *[[:space:]:]*) return 0 ;;
        *) return 1 ;;
    esac
}

if has_unsafe_path "$SRC" || has_unsafe_path "$BUILD"; then
    STAGE_ROOT=${MIRAGE_QEMU_STAGE_ROOT:-/tmp}
    if has_unsafe_path "$STAGE_ROOT"; then
        STAGE_ROOT=/tmp
    fi
    STAGE_ROOT=${STAGE_ROOT%/}
    STAGE_SRC=$STAGE_ROOT/mirage-qemu-src
    STAGE_BUILD=$STAGE_ROOT/mirage-qemu-build
    echo "build path contains spaces or colons; staging QEMU in $STAGE_ROOT"
    mkdir -p "$STAGE_SRC" "$STAGE_BUILD"
    # Keep downloaded subprojects (dtc, keycodemapdb, ...) that meson fetched
    # into the staging tree; without --delete a mirror never removes them.
    rsync -a --exclude='.git' --exclude='/build/' --exclude='/roms/' --exclude='/subprojects/' \
        "$SRC/" "$STAGE_SRC/"
    if [ -d "$SRC/subprojects" ]; then
        rsync -a --exclude='.git' "$SRC/subprojects/" "$STAGE_SRC/subprojects/"
    fi
    # roms is ~1.2 GB of device firmware; link it instead of copying so the
    # staging tree stays small.
    rm -rf "$STAGE_SRC/roms"
    ln -sfn "$SRC/roms" "$STAGE_SRC/roms"
    FINAL_BUILD=$BUILD
    SRC=$STAGE_SRC
    BUILD=$STAGE_BUILD
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
if [ -n "$FINAL_BUILD" ]; then
    mkdir -p "$FINAL_BUILD"
    cp -f "$BUILD/qemu-system-arm" "$FINAL_BUILD/qemu-system-arm"
    echo "built $FINAL_BUILD/qemu-system-arm"
else
    echo "built $BUILD/qemu-system-arm"
fi
