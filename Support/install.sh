#!/bin/bash
# Build, install, and (re)load the apple-bridge helper LaunchAgent.
#
# Naming: every identifier this repo owns starts `org.dempsay`. The label was
# `com.org.dempsay.…` once; LEGACY_LABEL below retires it, because a leftover
# agent under the old label would compete for the same socket.
#
# Signing: prefers the stable "apple-bridge Dev Signing" identity (self-signed,
# trusted for code signing in the user domain). With it, TCC's designated
# requirement is `identifier ... and certificate root ...`, so rebuilds do NOT
# re-prompt. Falls back to ad-hoc only if that identity is missing — ad-hoc
# anchors to the cdhash, which changes every build and re-prompts every time.
set -euo pipefail

cd "$(dirname "$0")/.."

LABEL=org.dempsay.apple-bridge.helper
LEGACY_LABEL=com.org.dempsay.apple-bridge.helper
BASE="$HOME/Library/Application Support/apple-bridge"
BINDIR="$HOME/.local/bin"
HELPER="$BINDIR/apple-bridge-helper"
MCP="$BINDIR/apple-bridge-mcp"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> swift build"
swift build --product apple-bridge-helper
swift build --product apple-bridge-mcp

HELPER_BIN=".build/debug/apple-bridge-helper"
MCP_BIN=".build/debug/apple-bridge-mcp"
[ -x "$HELPER_BIN" ] || { echo "missing built product: $HELPER_BIN" >&2; exit 1; }
[ -x "$MCP_BIN" ] || { echo "missing built product: $MCP_BIN" >&2; exit 1; }

SIGN_IDENTITY="apple-bridge Dev Signing"
SIGN_ROOT="3c6196c867280334c4e6f4a25121c35b09b03ff6"

# A locked keychain makes `security find-identity` still list the identity but
# marked CSSMERR_TP_NOT_TRUSTED, and makes codesign fail with errSecInternalComponent.
# Diagnose it here rather than letting the failure surface as a silent ad-hoc binary.
if ! security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    cat >&2 <<EOF
==> login keychain is locked, so the signing identity is unreachable.

  security unlock-keychain $HOME/Library/Keychains/login.keychain-db

Then re-run this script. Nothing has been installed and the running agent has not
been touched.
EOF
    exit 1
fi

# Sign to a staging path and verify BEFORE replacing the installed binary or
# booting out the running agent. A signing failure must never leave a
# mis-signed helper in place of a working one: an ad-hoc signature changes the
# designated requirement to the cdhash, which silently invalidates the TCC grant.
STAGED="$BASE/.helper.staged"
mkdir -p "$BINDIR" "$BASE"
chmod 700 "$BASE"
cp "$HELPER_BIN" "$STAGED"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "==> codesign helper with stable identity: $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" "$STAGED"
    if ! codesign -d -r- "$STAGED" 2>&1 | grep -qi "$SIGN_ROOT"; then
        echo "==> signed, but the designated requirement does not anchor to the identity of" >&2
        echo "    record (root $SIGN_ROOT). Refusing to install — this would re-prompt on" >&2
        echo "    every rebuild. Do NOT mint a second cert with the same CN." >&2
        rm -f "$STAGED"
        exit 1
    fi
else
    echo "==> ad-hoc codesign helper (identity '$SIGN_IDENTITY' not found; expect a TCC re-prompt on every rebuild)" >&2
    codesign --force --sign - "$STAGED"
fi

echo "==> installing binaries to $BINDIR"
# Only now that the signature is known good: stop the running agent and swap in
# the signed binary.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# Retire the old com.org label. Leaving it loaded would run a second helper
# against the same socket; it would exit 0 on the single-instance probe, but two
# agents registered for one helper is a confusing thing to debug later.
if launchctl print "gui/$(id -u)/$LEGACY_LABEL" >/dev/null 2>&1; then
    echo "==> retiring legacy agent $LEGACY_LABEL"
    launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
fi
rm -f "$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
rm -f "$BASE/helper.sock" "$BASE/apple-bridge-helper"
mv "$STAGED" "$HELPER"
cp "$MCP_BIN" "$MCP"
chmod 755 "$HELPER" "$MCP"

# The MCP binary never touches EventKit, so an ad-hoc signature is enough to run.
echo "==> ad-hoc codesign mcp"
codesign --force --sign - "$MCP"

echo "==> writing LaunchAgent to $AGENT"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" "Support/$LABEL.plist" > "$AGENT"
plutil -lint "$AGENT"

echo "==> bootstrapping agent"
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "done."
echo "  helper:    $HELPER"
echo "  mcp:       $MCP"
echo "  logs:      $BASE/helper.log"
echo "  to remove: launchctl bootout gui/$(id -u)/$LABEL && rm $AGENT $HELPER $MCP"
