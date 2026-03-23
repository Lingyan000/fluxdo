#!/bin/bash
# Build Rust DOH Proxy for Desktop (macOS/Linux)
# Usage: ./scripts/build_desktop.sh [--debug]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$PROJECT_ROOT/core/doh_proxy"

# Default to release build
BUILD_TYPE="release"
CARGO_FLAG="--release"

if [ "$1" == "--debug" ]; then
    BUILD_TYPE="debug"
    CARGO_FLAG=""
fi

echo "=== Building Rust DOH Proxy for Desktop ($BUILD_TYPE) ==="

cd "$RUST_DIR"
cargo build $CARGO_FLAG --features ech

# Determine executable name based on OS
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "win32" ]]; then
    EXE_NAME="doh_proxy_bin.exe"
else
    EXE_NAME="doh_proxy_bin"
fi

EXE_PATH="$RUST_DIR/target/$BUILD_TYPE/$EXE_NAME"

if [ -f "$EXE_PATH" ]; then
    echo ""
    echo "=== Build complete! ==="
    echo "Executable: $EXE_PATH"
    ls -lh "$EXE_PATH"
else
    echo "Build failed: $EXE_PATH not found"
    exit 1
fi
