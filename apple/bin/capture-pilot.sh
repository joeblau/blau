#!/usr/bin/env bash
#
# capture-pilot.sh — capture a Pilot (macOS) window screenshot in demo mode.
#
# fastlane snapshot can't drive macOS, so Pilot is captured directly. This
# builds Pilot (Debug), launches the .app with the DEMO-MODE launch arguments
# (["-demoMode", "YES"]) so it renders representative fixture state with no live
# companion peers, waits for the window, then captures the frontmost Pilot
# window.
#
# NOTE: macOS window capture is interactive-ish. You may want to arrange the
# workspace (resize the window, pick panes) before the capture fires — set
# PILOT_CAPTURE_DELAY to add more lead time, or run with INTERACTIVE=1 to be
# prompted to press Return when the layout looks right.
#
# Output: web/public/screenshots/pilot/01-pilot.png
#
# Run from apple/:  ./bin/capture-pilot.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$APPLE_DIR/../web/public/screenshots/pilot"
OUT="$OUT_DIR/01-pilot.png"
mkdir -p "$OUT_DIR"

PROJECT="$APPLE_DIR/blau.xcodeproj"
SCHEME="Pilot"
CAPTURE_DELAY="${PILOT_CAPTURE_DELAY:-5}"

echo "==> Building $SCHEME (Debug)"
DERIVED="$(mktemp -d)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED" \
  build | tail -5

APP_PATH="$(/usr/bin/find "$DERIVED/Build/Products" -name 'Pilot.app' -maxdepth 3 | head -1)"
if [ -z "$APP_PATH" ]; then
  echo "ERROR: built Pilot.app not found under $DERIVED" >&2
  exit 1
fi
echo "    App: $APP_PATH"

echo "==> Launching Pilot in demo mode"
# -n forces a fresh instance; pass demo-mode launch args through to the app.
open -n "$APP_PATH" --args -demoMode YES

echo "==> Waiting ${CAPTURE_DELAY}s for the window to appear"
sleep "$CAPTURE_DELAY"

if [ "${INTERACTIVE:-0}" = "1" ]; then
  echo "==> Arrange the Pilot window, then press Return to capture..."
  read -r _
fi

# Find the frontmost Pilot window id via AppleScript, then capture just it.
echo "==> Locating Pilot window"
WINDOW_ID="$(osascript <<'OSA' 2>/dev/null || true
tell application "System Events"
  set procs to (every process whose name is "Pilot")
  if (count of procs) is 0 then return ""
end tell
tell application "Pilot" to activate
OSA
)"

# Prefer a precise window capture; fall back to interactive selection.
PILOT_WIN="$(/usr/bin/python3 - <<'PY' 2>/dev/null || true
import subprocess, json, sys
try:
    import Quartz
except Exception:
    sys.exit(0)
wins = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID)
for w in wins:
    if w.get('kCGWindowOwnerName') == 'Pilot' and w.get('kCGWindowLayer', 0) == 0:
        print(w.get('kCGWindowNumber'))
        break
PY
)"

if [ -n "$PILOT_WIN" ]; then
  echo "==> Capturing Pilot window #$PILOT_WIN -> $OUT"
  screencapture -o -l"$PILOT_WIN" "$OUT"
else
  echo "==> Could not resolve a window id automatically."
  echo "    Falling back to interactive region capture: drag to select the Pilot window."
  screencapture -o -i "$OUT"
fi

echo "==> Done: $OUT"
