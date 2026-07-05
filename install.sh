#!/bin/bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SUITE_DIR/build"
INSTALL_DIR="$HOME/.local/share/suite"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/sunshine"
FFMPEG_CACHE="${FFMPEG_CACHE:-$SUITE_DIR/.cache/ffmpeg-darwin-arm64}"

info() { printf '\033[0;34m[INFO]\033[0m %s\n' "$1"; }
ok() { printf '\033[0;32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$1"; exit 1; }

echo ""
echo "  Suite installer"
echo ""

info "Running pre-flight checks..."
[ "$(uname -m)" = "arm64" ] || error "Suite only supports Apple Silicon (arm64)."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || error "Suite requires macOS 14 or later."
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
git -C "$SUITE_DIR" submodule update --init --recursive

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

if [ -n "${FFMPEG_PREPARED_BINARIES:-}" ]; then
  CMAKE_ARGS+=("-DFFMPEG_PREPARED_BINARIES=$FFMPEG_PREPARED_BINARIES")
  info "Using FFmpeg binaries from $FFMPEG_PREPARED_BINARIES"
elif [ -f "$FFMPEG_CACHE/lib/libavcodec.a" ]; then
  CMAKE_ARGS+=("-DFFMPEG_PREPARED_BINARIES=$FFMPEG_CACHE")
  info "Using cached FFmpeg binaries from $FFMPEG_CACHE"
else
  warn "No prepared FFmpeg bundle found; set FFMPEG_PREPARED_BINARIES or FFMPEG_CACHE if the upstream download is unavailable."
fi

info "Configuring CMake..."
GIT_BRANCH="$(git -C "$SUITE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
GIT_DESCRIBE="$(git -C "$SUITE_DIR" describe --tags --dirty --always 2>/dev/null || echo 0.0.0)"
export BRANCH="${BRANCH:-$GIT_BRANCH}"
export BUILD_VERSION="${BUILD_VERSION:-${GIT_DESCRIBE#v}}"
export TAG="${TAG:-$GIT_DESCRIBE}"
export COMMIT="${COMMIT:-$(git -C "$SUITE_DIR" rev-parse --short HEAD)}"
cmake -S "$SUITE_DIR" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"

info "Building Suite..."
cmake --build "$BUILD_DIR" --target sunshine web-ui vd_helper -j"$(sysctl -n hw.ncpu)"
ok "Build complete"

info "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/assets" "$INSTALL_DIR/assets/web" "$BIN_DIR" "$CONFIG_DIR/scripts"

cp -f "$BUILD_DIR/sunshine" "$INSTALL_DIR/sunshine"
cp -f "$BUILD_DIR/vd_helper" "$INSTALL_DIR/vd_helper"
cp -Rf "$BUILD_DIR/assets/." "$INSTALL_DIR/assets/"
cp -Rf "$BUILD_DIR/assets/web/." "$INSTALL_DIR/assets/web/"

if [ -d "$SUITE_DIR/scripts" ]; then
  cp -f "$SUITE_DIR/scripts/"*.sh "$CONFIG_DIR/scripts/" 2>/dev/null || true
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
# Suite Configuration
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

cat > "$BIN_DIR/suite" <<'LAUNCHER'
#!/bin/bash
INSTALL_DIR="$HOME/.local/share/suite"
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

echo "Starting Suite..."
echo "  Web UI: https://localhost:47990"
exec "$BINARY" "$@"
LAUNCHER
chmod +x "$BIN_DIR/suite"
ln -sf "$BIN_DIR/suite" "$BIN_DIR/daylight"
ln -sf "$BIN_DIR/suite" "$BIN_DIR/lumen"

ok "Installed launcher to $BIN_DIR/suite"
echo ""
echo "Suite installed successfully."
echo "Start with: $BIN_DIR/suite"
echo "Set Web UI credentials with: $BIN_DIR/suite --creds username password"
