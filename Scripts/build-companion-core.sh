#!/bin/bash
set -euo pipefail
BRIDGE_DIR="$(cd "$(dirname "$0")/../AstroBoxBridge" && pwd)"
LIB="$BRIDGE_DIR/target/release/libmirage_astrobox.a"
if [ ! -f "$LIB" ] || [ "$BRIDGE_DIR/src" -nt "$LIB" ] || [ "$BRIDGE_DIR/Cargo.toml" -nt "$LIB" ]; then
    echo "Building AstroBoxBridge..."
    (cd "$BRIDGE_DIR" && cargo build --release)
else
    echo "AstroBoxBridge is up to date."
fi
