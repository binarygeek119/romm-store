#!/usr/bin/env bash
# Build a relocatable AppImage for RomM Store (Flutter Linux).
# Requires: Flutter Linux desktop + build deps (CMake, Ninja, GTK 3 dev, etc.).
# Run on Linux (or a Linux CI image), not from a Windows checkout of flutter via WSL
# unless you use a Linux-installed SDK.
#
# Usage: ./scripts/build_appimage.sh
# Optional: FLUTTER=/path/to/flutter MINIMAL_APPIMAGE=1 ./scripts/build_appimage.sh
#   MINIMAL_APPIMAGE=1 — only bundles the Flutter release folder (no linuxdeploy GTK
#   bundling); may miss system libraries on some distros.

set -euo pipefail

require_pkg_config() {
  local pkg="$1"
  if ! pkg-config --exists "$pkg"; then
    echo "error: missing required pkg-config package '$pkg'" >&2
    echo "Install Linux desktop deps, then rerun:" >&2
    echo "  Debian/Ubuntu: sudo apt install pkg-config clang cmake ninja-build libgtk-3-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libsecret-1-dev lld" >&2
    echo "  Fedora:        sudo dnf install pkgconf-pkg-config clang cmake ninja-build gtk3-devel gstreamer1-devel gstreamer1-plugins-base-devel libsecret-devel lld llvm" >&2
    echo "  Arch:          sudo pacman -S --needed pkgconf clang cmake ninja gtk3 gst-plugins-base-libs gstreamer libsecret lld" >&2
    exit 1
  fi
}

require_command() {
  local cmd="$1"
  local why="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command '$cmd' not found ($why)" >&2
    echo "Install Linux desktop deps, then rerun:" >&2
    echo "  Debian/Ubuntu: sudo apt install dpkg-dev" >&2
    echo "  Fedora:        sudo dnf install dpkg-dev" >&2
    echo "  Arch:          install package providing '$cmd' (typically via AUR: dpkg)" >&2
    exit 1
  fi
}

# Dart Linux native builds resolve ld.lld / ld next to Clang's LLVM bindir (e.g. /usr/lib/llvm-18/bin).
require_clang_llvm_linker() {
  command -v clang >/dev/null 2>&1 || return 0
  local maj
  maj="$(clang -dumpversion 2>/dev/null | cut -d. -f1)"
  [[ "$maj" =~ ^[0-9]+$ ]] || return 0
  local bindir="/usr/lib/llvm-${maj}/bin"
  [[ -d "$bindir" ]] || return 0
  if [[ -x "$bindir/ld.lld" ]] || [[ -x "$bindir/ld" ]]; then
    return 0
  fi
  echo "error: Dart needs ld.lld or ld in $bindir (LLVM ${maj}); none found." >&2
  echo "  Debian/Ubuntu: sudo apt install lld-${maj}" >&2
  echo "                 # or: sudo apt install lld" >&2
  echo "  Fedora:        sudo dnf install lld" >&2
  echo "  Arch:          sudo pacman -S lld" >&2
  exit 1
}

write_apprun() {
  cat > "$APPDIR/AppRun" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
exec "$HERE/usr/bin/romm-store" "$@"
EOF
  chmod +x "$APPDIR/AppRun"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FLUTTER="${FLUTTER:-flutter}"
require_pkg_config gtk+-3.0
require_pkg_config gstreamer-1.0
require_pkg_config libsecret-1
require_clang_llvm_linker
require_command dpkg-architecture "required by linuxdeploy GTK plugin"
"$FLUTTER" pub get
"$FLUTTER" build linux --release

VERSION="$(grep '^version:' pubspec.yaml | head -n1 | awk '{print $2}' | cut -d+ -f1)"
BUNDLE="$ROOT/build/linux/x64/release/bundle"
if [[ ! -x "$BUNDLE/romm-store" ]]; then
  echo "error: missing $BUNDLE/romm-store — is the Linux embedder enabled? (flutter config --enable-linux-desktop)" >&2
  exit 1
fi

DESKTOP="$ROOT/linux/packaging/romm-store.desktop"
ICON_SOURCE="$ROOT/freegosy_logo.png"
WORKDIR="$ROOT/build/appimage_out"
APPDIR="$WORKDIR/AppDir"
rm -rf "$WORKDIR"
mkdir -p "$APPDIR/usr/bin"
cp -a "$BUNDLE"/. "$APPDIR/usr/bin/"
ICON="$WORKDIR/romm-store.png"
cp "$ICON_SOURCE" "$ICON"

TOOLS="$ROOT/build/appimage_tools"
mkdir -p "$TOOLS"
export APPIMAGE_EXTRACT_AND_RUN=1

download_if_missing() {
  local url="$1"
  local dest="$2"
  if [[ ! -f "$dest" ]]; then
    echo "Downloading $(basename "$dest")..."
    curl -fsSL -o "$dest" "$url"
    chmod +x "$dest"
  fi
}

if [[ "${MINIMAL_APPIMAGE:-0}" == "1" ]]; then
  mkdir -p "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/512x512/apps"
  cp "$DESKTOP" "$APPDIR/usr/share/applications/romm-store.desktop"
  cp "$ICON" "$APPDIR/usr/share/icons/hicolor/512x512/apps/romm-store.png"
  cp "$DESKTOP" "$APPDIR/romm-store.desktop"
  ln -sf "usr/share/icons/hicolor/512x512/apps/romm-store.png" "$APPDIR/.DirIcon"
  write_apprun
  APPIMAGETOOL="$TOOLS/appimagetool-x86_64.AppImage"
  download_if_missing "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage" "$APPIMAGETOOL"
  OUT="$WORKDIR/RomM_Store-${VERSION}-x86_64.AppImage"
  ARCH=x86_64 VERSION="$VERSION" "$APPIMAGETOOL" "$APPDIR" "$OUT"
  echo "Built: $OUT"
  exit 0
fi

LINUXDEPLOY="$TOOLS/linuxdeploy-x86_64.AppImage"
download_if_missing "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage" "$LINUXDEPLOY"
download_if_missing "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh" "$TOOLS/linuxdeploy-plugin-gtk.sh"

export ARCH=x86_64
export VERSION

# GTK + AppImage plugins are picked up from the same directory as linuxdeploy.
(
  cd "$WORKDIR"
  "$LINUXDEPLOY" \
    --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/romm-store" \
    --desktop-file "$DESKTOP" \
    --icon-file "$ICON" \
    --plugin gtk \
    --output appimage
)

shopt -s nullglob
imgs=( "$WORKDIR"/*.AppImage )
if [[ ${#imgs[@]} -eq 0 ]]; then
  echo "error: linuxdeploy did not produce an AppImage under $WORKDIR" >&2
  exit 1
fi

APPIMG="${imgs[0]}"
FINAL="$WORKDIR/RomM_Store-${VERSION}-x86_64.AppImage"
if [[ "$APPIMG" != "$FINAL" ]]; then
  mv -f "$APPIMG" "$FINAL"
fi
echo "Built: $FINAL"
