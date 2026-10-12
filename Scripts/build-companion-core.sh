#!/bin/bash
set -euo pipefail

# Xcode runs build phases without the login shell's environment, so cargo
# (rustup's ~/.cargo/bin) is not on PATH there.
if [ -f "${CARGO_HOME:-$HOME/.cargo}/env" ]; then
    . "${CARGO_HOME:-$HOME/.cargo}/env"
fi
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found; install Rust (https://rustup.rs) to build the companion core" >&2
    exit 1
fi

BRIDGE_DIR="$(cd "$(dirname "$0")/../AstroBoxBridge" && pwd)"
LIB="$BRIDGE_DIR/target/release/libmirage_astrobox.a"
if [ ! -f "$LIB" ] || [ "$BRIDGE_DIR/src" -nt "$LIB" ] || [ "$BRIDGE_DIR/Cargo.toml" -nt "$LIB" ]; then
    echo "Building the companion core..."
    (cd "$BRIDGE_DIR" && cargo build --release)
else
    echo "companion core is up to date."
fi
