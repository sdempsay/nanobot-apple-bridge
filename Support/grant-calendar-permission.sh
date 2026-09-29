#!/bin/bash
# Grant Calendar access to apple-bridge helper via tccutil
# Usage: ./grant-calendar-permission.sh

set -e

BUNDLE_ID="com.org.dempsay.apple-bridge.helper"

echo "Granting Calendar access to $BUNDLE_ID..."

# Reset first to ensure clean state
tccutil reset Calendars $BUNDLE_ID

# The actual grant requires a GUI prompt on Apple Silicon
# tccutil cannot silently grant Calendar access
echo "TCC prompt should appear shortly — click Allow to grant Calendar access."
echo "If no prompt appears, manually add $BUNDLE_ID in: System Settings → Privacy & Security → Calendars"
