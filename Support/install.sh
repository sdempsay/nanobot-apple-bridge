#!/bin/bash
# Build, install, and (re)load the apple-bridge helper LaunchAgent.
#
# Signing: prefers the stable "apple-bridge Dev Signing" identity (self-signed,
# trusted for code signing in the user domain). With it, TCC's designated
# requirement is `identifier ... and certificate root ...`, so rebuilds do NOT
# re-prompt. Falls back to ad-hoc only if that identity is missing — ad-hoc
# anchors to the cdhash, which changes every build and re-prompts every time.
set -euo pipefail

cd "$(dirname "$0")/.."

LABEL=com.org.dempsay.apple-bridge.helper
BASE="$HOME/Library/Application Support/apple-bridge"
DEST="$BASE/apple-bridge-helper"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> swift build"
swift build --product apple-bridge-helper

BIN=".build/debug/apple-bridge-helper"
[ -x "$BIN" ] || { echo "missing built product: $BIN" >&2; exit 1; }

echo "==> installing binary to $DEST"
mkdir -p "$BASE"
chmod 700 "$BASE"
# Stop the running agent before overwriting the binary it executes.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$BASE/helper.sock"
cp "$BIN" "$DEST"
chmod 755 "$DEST"

SIGN_IDENTITY="apple-bridge Dev Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "==> codesign with stable identity: $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" "$DEST"
else
    echo "==> ad-hoc codesign (identity '$SIGN_IDENTITY' not found; expect a TCC re-prompt on every rebuild)" >&2
    codesign --force --sign - "$DEST"
fi

echo "==> writing LaunchAgent to $AGENT"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" "Support/$LABEL.plist" > "$AGENT"
plutil -lint "$AGENT"

echo "==> bootstrapping agent"
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "done."
echo "  logs:      $BASE/helper.log"
echo "  to remove: launchctl bootout gui/$(id -u)/$LABEL && rm $AGENT"
