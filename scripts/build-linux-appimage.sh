#!/usr/bin/env bash
# Build Zterm untuk Linux lalu bungkus jadi AppImage.
#
# Butuh (Ubuntu/Debian): build-essential pkg-config libssl-dev libgtk-4-dev libadwaita-1-dev
#                        libvte-2.91-gtk4-dev curl file
# Hasil: dist/Zterm-Linux-<arch>.AppImage
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/apps/linux"
ARCH="$(uname -m)"
WORK="$ROOT/dist/appimage-$ARCH"
APPDIR="$WORK/AppDir"
TOOLS="$WORK/tools"

echo "==> cargo build --release"
cargo build --release --manifest-path "$APP/Cargo.toml"

echo "==> Menyusun AppDir"
rm -rf "$APPDIR"
install -Dm755 "$APP/target/release/zterm" "$APPDIR/usr/bin/zterm"
install -Dm644 "$APP/data/com.latiefahmad.zterm.desktop" "$APPDIR/usr/share/applications/com.latiefahmad.zterm.desktop"
install -Dm644 "$APP/data/icons/com.latiefahmad.zterm.png" "$APPDIR/usr/share/icons/hicolor/512x512/apps/com.latiefahmad.zterm.png"
mkdir -p "$APPDIR/usr/share/icons/hicolor/scalable/actions"
cp -r "$APP/data/icons/hicolor/scalable/actions/." "$APPDIR/usr/share/icons/hicolor/scalable/actions/"
install -Dm644 "$APP/data/com.latiefahmad.zterm.metainfo.xml" "$APPDIR/usr/share/metainfo/com.latiefahmad.zterm.metainfo.xml"

echo "==> Mengunduh linuxdeploy"
mkdir -p "$TOOLS"
fetch() { [ -x "$TOOLS/$1" ] || { curl -fL -o "$TOOLS/$1" "$2"; chmod +x "$TOOLS/$1"; }; }
fetch "linuxdeploy-$ARCH.AppImage" \
  "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$ARCH.AppImage"
fetch "linuxdeploy-plugin-gtk.sh" \
  "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh"

echo "==> Membuat AppImage"
cd "$WORK"
export DEPLOY_GTK_VERSION=4
export APPIMAGE_EXTRACT_AND_RUN=1   # jalan juga di container tanpa FUSE
export OUTPUT="$ROOT/dist/Zterm-Linux-$ARCH.AppImage"
PATH="$TOOLS:$PATH" "$TOOLS/linuxdeploy-$ARCH.AppImage" \
  --appdir "$APPDIR" \
  --desktop-file "$APPDIR/usr/share/applications/com.latiefahmad.zterm.desktop" \
  --icon-file "$APPDIR/usr/share/icons/hicolor/512x512/apps/com.latiefahmad.zterm.png" \
  --plugin gtk \
  --output appimage

echo "Selesai: $OUTPUT"
