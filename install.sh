#!/bin/bash
set -euo pipefail

DAYLIGHT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$DAYLIGHT_DIR/build"
INSTALL_DIR="$HOME/.local/share/daylight"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/sunshine"
FFMPEG_CACHE="$HOME/Documents/GitHub/mhadifilms/daylight-reference/ffmpeg-darwin-arm64"

info() { printf '\033[0;34m[INFO]\033[0m %s\n' "$1"; }
ok() { printf '\033[0;32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$1"; exit 1; }

echo ""
echo "  Daylight installer"
echo ""

info "Running pre-flight checks..."
[ "$(uname -m)" = "arm64" ] || error "Daylight only supports Apple Silicon (arm64)."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || error "Daylight requires macOS 14 or later."
xcode-select -p >/dev/null 2>&1 || error "Install Xcode Command Line Tools first: xcode-select --install"
command -v brew >/dev/null 2>&1 || error "Install Homebrew first."
ok "Platform checks passed"

info "Installing build dependencies via Homebrew..."
for dep in cmake boost pkg-config openssl@3 opus llvm doxygen graphviz node icu4c@78 miniupnpc; do
  if brew list "$dep" >/dev/null 2>&1; then
    ok "$dep (already installed)"
  else
    info "Installing $dep..."
    brew install "$dep"
    ok "$dep"
  fi
done

info "Initializing submodules..."
git -C "$DAYLIGHT_DIR" submodule update --init --recursive

SDK_PATH="$(xcrun --show-sdk-path)"
CXX_HEADERS="$SDK_PATH/usr/include/c++/v1"
OPENSSL_PREFIX="$(brew --prefix openssl@3)"

CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_WERROR=ON
  -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX"
  -DSUNSHINE_ASSETS_DIR=sunshine/assets
  -DSUNSHINE_BUILD_HOMEBREW=ON
  -DSUNSHINE_ENABLE_TRAY=ON
  -DBOOST_USE_STATIC=OFF
  -DCMAKE_OSX_SYSROOT="$SDK_PATH"
  -DCMAKE_CXX_FLAGS="-nostdinc++ -cxx-isystem $CXX_HEADERS -std=gnu++2b -I$OPENSSL_PREFIX/include"
  -DCMAKE_C_FLAGS="-I$OPENSSL_PREFIX/include"
)

if [ -z "${FFMPEG_PREPARED_BINARIES:-}" ] && [ -f "$FFMPEG_CACHE/lib/libavcodec.a" ]; then
  CMAKE_ARGS+=("-DFFMPEG_PREPARED_BINARIES=$FFMPEG_CACHE")
  info "Using cached FFmpeg binaries from $FFMPEG_CACHE"
elif [ -n "${FFMPEG_PREPARED_BINARIES:-}" ]; then
  CMAKE_ARGS+=("-DFFMPEG_PREPARED_BINARIES=$FFMPEG_PREPARED_BINARIES")
  info "Using FFmpeg binaries from $FFMPEG_PREPARED_BINARIES"
else
  warn "No cached FFmpeg bundle found; CMake will try the upstream download."
fi

info "Configuring CMake..."
export BRANCH="${BRANCH:-master}"
export BUILD_VERSION="${BUILD_VERSION:-2026.703.144423}"
export TAG="${TAG:-v2026.703.144423}"
export COMMIT="${COMMIT:-$(git -C "$DAYLIGHT_DIR" rev-parse --short HEAD)}"
cmake -S "$DAYLIGHT_DIR" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"

info "Building Daylight..."
cmake --build "$BUILD_DIR" --target sunshine web-ui vd_helper get_display_origin -j"$(sysctl -n hw.ncpu)"
ok "Build complete"

info "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/assets" "$INSTALL_DIR/assets/web" "$BIN_DIR" "$CONFIG_DIR/scripts"

cp -f "$BUILD_DIR/sunshine" "$INSTALL_DIR/sunshine"
cp -f "$BUILD_DIR/vd_helper" "$INSTALL_DIR/vd_helper"
cp -f "$BUILD_DIR/get_display_origin" "$INSTALL_DIR/get_display_origin"
cp -Rf "$BUILD_DIR/assets/." "$INSTALL_DIR/assets/"
cp -Rf "$BUILD_DIR/assets/web/." "$INSTALL_DIR/assets/web/"

if [ -d "$DAYLIGHT_DIR/scripts" ]; then
  cp -f "$DAYLIGHT_DIR/scripts/"*.sh "$CONFIG_DIR/scripts/" 2>/dev/null || true
  chmod +x "$CONFIG_DIR/scripts/"*.sh 2>/dev/null || true
fi

cat > "$INSTALL_DIR/hid_entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.hid.virtual.device</key>
  <true/>
</dict>
</plist>
PLIST

if [ ! -f "$CONFIG_DIR/sunshine.conf" ]; then
  cat > "$CONFIG_DIR/sunshine.conf" <<'CONF'
# Daylight Configuration
audio_sink = system
virtual_display = enabled
upnp = enabled
max_bitrate = 150000
CONF
  ok "Created default config at $CONFIG_DIR/sunshine.conf"
else
  warn "Leaving existing $CONFIG_DIR/sunshine.conf unchanged"
fi

if [ ! -f "$CONFIG_DIR/apps.json" ]; then
  cat > "$CONFIG_DIR/apps.json" <<'APPS'
{
  "env": {
    "PATH": "$(PATH):$(HOME)/.local/bin"
  },
  "apps": [
    {
      "name": "Desktop"
    }
  ]
}
APPS
  ok "Created default apps file at $CONFIG_DIR/apps.json"
fi

cat > "$BIN_DIR/daylight" <<'LAUNCHER'
#!/bin/bash
INSTALL_DIR="$HOME/.local/share/daylight"
ENTITLEMENTS="$INSTALL_DIR/hid_entitlements.plist"
BINARY="$INSTALL_DIR/sunshine"

if [ "${1:-}" = "--creds" ]; then
  "$BINARY" "$@"
  exit $?
fi

if nvram boot-args 2>/dev/null | grep -q "amfi_get_out_of_my_way=1"; then
  codesign --sign - --entitlements "$ENTITLEMENTS" --force "$BINARY" 2>/dev/null || true
  [ -f "$INSTALL_DIR/vd_helper" ] && codesign --sign - --force "$INSTALL_DIR/vd_helper" 2>/dev/null || true
fi

echo "Starting Daylight..."
echo "  Web UI: https://localhost:47990"
exec "$BINARY" "$@"
LAUNCHER
chmod +x "$BIN_DIR/daylight"
ln -sf "$BIN_DIR/daylight" "$BIN_DIR/lumen"

ok "Installed launcher to $BIN_DIR/daylight"
echo ""
echo "Daylight installed successfully."
echo "Start with: $BIN_DIR/daylight"
echo "Set Web UI credentials with: $BIN_DIR/daylight --creds username password"
