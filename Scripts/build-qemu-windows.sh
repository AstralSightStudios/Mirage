#!/bin/sh
# Build qemu-system-arm.exe from the qemu-miwear submodule on Windows and
# stage it for the Windows package: the exe, the MinGW DLLs it loads and
# pc-bios/keymaps (LaunchPlan passes that directory with -L for VNC).
#
# Runs in an MSYS2 MINGW64 or UCRT64 shell with these packages:
#   pacman -S --needed make git diffutils \
#     $MINGW_PACKAGE_PREFIX-{gcc,glib2,pixman,python,meson,ninja,pkgconf}
#
# Same feature set as Scripts/build-qemu.sh: TCG, VNC, pixman.
#
# usage: Scripts/build-qemu-windows.sh [DEST]   (default .build/windows/qemu)
#   QEMU_BUILD_DIR   build directory (default External/qemu-miwear/build-windows)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=$ROOT/External/qemu-miwear
BUILD=${QEMU_BUILD_DIR:-$SRC/build-windows}
DEST=${1:-$ROOT/.build/windows/qemu}

if [ -z "$MSYSTEM_PREFIX" ]; then
    echo "run this in an MSYS2 MINGW64 or UCRT64 shell" >&2
    exit 1
fi
if [ ! -f "$SRC/configure" ]; then
    echo "qemu-miwear submodule missing: git submodule update --init External/qemu-miwear" >&2
    exit 1
fi

mkdir -p "$BUILD"
cd "$BUILD"
if [ ! -f build.ninja ]; then
    "$SRC/configure" \
        --target-list=arm-softmmu \
        --without-default-features \
        --enable-system --enable-tcg --enable-vnc --enable-pixman \
        --disable-werror --disable-debug-info --enable-strip
fi
make -j"$(nproc)" qemu-system-arm

rm -rf "$DEST"
mkdir -p "$DEST/pc-bios"
cp qemu-system-arm.exe "$DEST/"
# the MinGW runtime and libraries (glib, pixman, ...) next to the exe
ldd qemu-system-arm.exe | awk '{print $3}' | grep -i "^$MSYSTEM_PREFIX/" | sort -u | while read -r dll; do
    cp "$dll" "$DEST/"
done
cp -R "$SRC/pc-bios/keymaps" "$DEST/pc-bios/"
"$DEST/qemu-system-arm.exe" --version | head -1
echo "staged $(ls "$DEST" | wc -l) files in $DEST"
