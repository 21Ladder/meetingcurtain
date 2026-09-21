#!/usr/bin/env bash
# Builds MeetingCurtain.app.
#
#   ./build.sh            build into build/MeetingCurtain.app
#   ./build.sh install    build, install to ~/Applications, and (re)start it
#
# Set SIGN_IDENTITY to a code-signing identity (e.g. "Apple Development: …") to sign with a stable
# identity; macOS then remembers the Calendar permission across rebuilds. Default is ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MeetingCurtain"
BUNDLE_ID="com.manu.meetingcurtain"
APP="build/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "▸ Running tests"
swift test --quiet

echo "▸ Compiling (release)"
swift build -c release --product "$APP_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"

if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "▸ Drawing app icon"
    rm -rf build/AppIcon.iconset
    mkdir -p build
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
strip -x "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "▸ Signing ($([[ "$SIGN_IDENTITY" == "-" ]] && echo ad-hoc || echo "$SIGN_IDENTITY"))"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

echo "✓ Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "install" ]]; then
    DEST="$HOME/Applications/$APP_NAME.app"
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "▸ Stopping the running copy"
        pkill -x "$APP_NAME" || true
        for _ in {1..50}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.1; done
    fi
    echo "▸ Installing to $DEST"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "✓ Installed and started. It registers itself to launch at login."
fi
