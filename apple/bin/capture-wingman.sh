#!/usr/bin/env bash
#
# capture-wingman.sh — capture a Wingman (watchOS) screenshot in demo mode.
#
# fastlane snapshot is iOS-only, so the watch app is captured directly via
# simctl. This boots a watchOS simulator, builds + installs Wingman, launches
# it with the DEMO-MODE launch arguments (["-demoMode", "YES"]) so it renders
# representative fixture state with no live Pilot peer, waits for the UI to
# settle, then grabs a PNG.
#
# Output: workers/web/public/screenshots/wingman/01-wingman.png
#
# Run from apple/:  ./bin/capture-wingman.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$APPLE_DIR/../workers/web/public/screenshots/wingman"
OUT="$OUT_DIR/01-wingman.png"
mkdir -p "$OUT_DIR"

# Chosen sim: newest available Apple Watch (watchOS 26.x matches the project's
# watchOS 26.0 deployment target). Override with WINGMAN_SIM if you like.
SIM_NAME="${WINGMAN_SIM:-Apple Watch Series 11 (46mm)}"
SCHEME="Wingman Watch App"
PROJECT="$APPLE_DIR/blau.xcodeproj"
BUNDLE_ID="app.blau.copilot.watchkitapp"

echo "==> Resolving simulator: $SIM_NAME"
UDID="$(xcrun simctl list devices available | grep -F "$SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
if [ -z "$UDID" ]; then
  echo "ERROR: no available simulator named '$SIM_NAME'." >&2
  echo "Available watch sims:" >&2
  xcrun simctl list devices available | grep -i watch >&2
  exit 1
fi
echo "    UDID: $UDID"

echo "==> Booting simulator"
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$UDID" -b

echo "==> Building $SCHEME (Debug)"
DERIVED="$(mktemp -d)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  build | tail -5

APP_PATH="$(/usr/bin/find "$DERIVED/Build/Products" -name 'Wingman.app' -maxdepth 3 | head -1)"
if [ -z "$APP_PATH" ]; then
  echo "ERROR: built Wingman.app not found under $DERIVED" >&2
  exit 1
fi
echo "    App: $APP_PATH"

echo "==> Installing + launching in demo mode"
xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl launch "$UDID" "$BUNDLE_ID" -demoMode YES || true

echo "==> Waiting for UI to settle"
sleep 6

echo "==> Capturing screenshot -> $OUT"
xcrun simctl io "$UDID" screenshot "$OUT"
echo "==> Done: $OUT"
