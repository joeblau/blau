#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$APPLE_ROOT/blau.xcodeproj"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0.app/Contents/Developer}"
export DEVELOPER_DIR
export DISABLE_SWIFTLINT=YES
export BLAU_CHROMIUM_CODESIGN_TIMESTAMP="${BLAU_CHROMIUM_CODESIGN_TIMESTAMP:-NO}"
TEST_CODE_SIGN_IDENTITY="${BLAU_CHROMIUM_TEST_CODE_SIGN_IDENTITY:-Apple Development}"
TEST_DEVELOPMENT_TEAM="${BLAU_CHROMIUM_TEST_DEVELOPMENT_TEAM:-K78G42H4U2}"
TEST_ARCHITECTURE="${BLAU_CHROMIUM_TEST_ARCHITECTURE:-$(uname -m)}"
signing_settings=(
  "CODE_SIGN_IDENTITY=$TEST_CODE_SIGN_IDENTITY"
  "DEVELOPMENT_TEAM=$TEST_DEVELOPMENT_TEAM"
  "CODE_SIGNING_REQUIRED=YES"
)
if [[ "$TEST_CODE_SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
  # Xcode's automatic signing accepts Apple Development but rejects an
  # explicit Developer ID identity. Release smoke tests have only the imported
  # Developer ID key, so make that override consistently manual for every
  # target in the hosted test graph.
  signing_settings+=("CODE_SIGN_STYLE=Manual")
fi

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  printf 'Chromium runtime test error: Xcode developer directory not found: %s\n' \
    "$DEVELOPER_DIR" >&2
  exit 1
fi
xcode_version="$(xcodebuild -version)"
if ! grep -Eq '^Xcode 26\.' <<< "$xcode_version"; then
  printf 'Chromium runtime test error: the pinned runtime requires Xcode 26.x\n' \
    >&2
  exit 1
fi
case "$TEST_ARCHITECTURE" in
  arm64|x86_64) ;;
  *)
    printf 'Chromium runtime test error: unsupported architecture: %s\n' \
      "$TEST_ARCHITECTURE" >&2
    exit 1
    ;;
esac

# When a result root is provided (the release workflow uploads it on
# failure), emit an xcresult per architecture so the exact failing
# assertion survives the -quiet log.
result_settings=()
if [[ -n "${BLAU_CHROMIUM_TEST_RESULT_ROOT:-}" ]]; then
  mkdir -p "$BLAU_CHROMIUM_TEST_RESULT_ROOT"
  result_settings=(
    -resultBundlePath
    "$BLAU_CHROMIUM_TEST_RESULT_ROOT/gate-$TEST_ARCHITECTURE.xcresult"
  )
fi

xcodebuild \
  -quiet \
  -project "$PROJECT" \
  -scheme PilotTests \
  -configuration Chromium \
  -destination 'platform=macOS' \
  -only-testing:PilotTests/ChromiumRealEngineSmokeTests \
  -skipPackagePluginValidation \
  "${result_settings[@]}" \
  ENABLE_TESTABILITY=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES \
  ARCHS="$TEST_ARCHITECTURE" \
  ONLY_ACTIVE_ARCH=YES \
  "${signing_settings[@]}" \
  test
