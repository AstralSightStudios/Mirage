#!/bin/sh
# Copy qemu-system-arm and the non-system libraries it loads into
# Mirage.app/Contents/Helpers/qemu, rewriting install names to @rpath so the
# app runs without Homebrew. Skipped when QEMU has not been built.
# usage: Scripts/bundle-qemu.sh <path to Mirage.app>
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=$1
QEMU=${QEMU_BINARY:-$ROOT/External/qemu-miwear/build/qemu-system-arm}
if [ ! -x "$QEMU" ]; then
    echo "warning: $QEMU not built; Mirage will look for QEMU at run time (make qemu)"
    exit 0
fi
DEST=$APP/Contents/Helpers/qemu
mkdir -p "$DEST/bin" "$DEST/lib"
set +e
if [ "$DEST/bin/qemu-system-arm" -nt "$QEMU" ] 2>/dev/null; then
    exit 0
fi
cp -f "$QEMU" "$DEST/bin/qemu-system-arm"
chmod u+w "$DEST/bin/qemu-system-arm"

# non-system dylibs, recursively
deps() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -v -e '^/usr/lib/' -e '^/System/' -e '^@' || true; }
copy_deps() {
    for dep in $(deps "$1"); do
        name=$(basename "$dep")
        install_name_tool -change "$dep" "@rpath/$name" "$2" 2>/dev/null || true
        if [ ! -f "$DEST/lib/$name" ]; then
            cp -f "$dep" "$DEST/lib/$name"
            chmod u+w "$DEST/lib/$name"
            install_name_tool -id "@rpath/$name" "$DEST/lib/$name" 2>/dev/null || true
            copy_deps "$DEST/lib/$name" "$DEST/lib/$name"
        fi
    done
}
copy_deps "$DEST/bin/qemu-system-arm" "$DEST/bin/qemu-system-arm"
for lib in "$DEST"/lib/*.dylib; do
    for dep in $(deps "$lib"); do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$lib" 2>/dev/null
    done
done
install_name_tool -add_rpath "@executable_path/../lib" "$DEST/bin/qemu-system-arm" 2>/dev/null || true
# install_name_tool invalidates signatures; re-sign ad hoc
for f in "$DEST"/lib/*.dylib "$DEST/bin/qemu-system-arm"; do
    codesign --force --sign - "$f" 2>/dev/null
done
if ! "$DEST/bin/qemu-system-arm" --version >/dev/null 2>&1; then
    echo "error: the bundled qemu-system-arm does not start" >&2
    rm -rf "$DEST"
    exit 1
fi
echo "bundled $(basename "$QEMU") with $(ls "$DEST/lib" | wc -l | tr -d ' ') libraries"
