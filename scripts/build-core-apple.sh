#!/usr/bin/env bash
# Build zterm-core untuk macOS (arm64 + x86_64) → ZtermCoreFFI.xcframework + binding Swift.
# Output: apps/macos/Frameworks/ZtermCoreFFI.xcframework dan apps/macos/Zterm/Core/Generated/zterm_core.swift
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

ROOT="$PWD"
CORE="$ROOT/core"
OUT="$ROOT/apps/macos/Frameworks"
GEN="$ROOT/apps/macos/Zterm/Core/Generated"
TMP="$CORE/target/apple"
export MACOSX_DEPLOYMENT_TARGET=14.0

rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null

cd "$CORE"
cargo build --release --lib --target aarch64-apple-darwin
cargo build --release --lib --target x86_64-apple-darwin

rm -rf "$TMP" && mkdir -p "$TMP/headers" "$TMP/lib" "$GEN" "$OUT"

# Binding Swift dibuat dari library (mode proc-macro UniFFI)
cargo run --quiet --release --features bindgen --bin uniffi-bindgen -- \
  generate --library "target/aarch64-apple-darwin/release/libzterm_core.dylib" \
  --language swift --out-dir "$TMP/bindings"

cp "$TMP/bindings/zterm_core.swift" "$GEN/"
cp "$TMP/bindings/zterm_coreFFI.h" "$TMP/headers/"
cp "$TMP/bindings/zterm_coreFFI.modulemap" "$TMP/headers/module.modulemap"

lipo -create \
  target/aarch64-apple-darwin/release/libzterm_core.a \
  target/x86_64-apple-darwin/release/libzterm_core.a \
  -output "$TMP/lib/libzterm_core.a"

rm -rf "$OUT/ZtermCoreFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$TMP/lib/libzterm_core.a" -headers "$TMP/headers" \
  -output "$OUT/ZtermCoreFFI.xcframework" >/dev/null

echo "✓ ZtermCoreFFI.xcframework + zterm_core.swift siap"
