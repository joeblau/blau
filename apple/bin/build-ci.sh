#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$APPLE_ROOT/blau.xcodeproj"
DERIVED_ROOT="${BLAU_DERIVED_DATA:-${TMPDIR:-/tmp}/blau-builds}"
PACKAGES="${BLAU_SOURCE_PACKAGES:-${TMPDIR:-/tmp}/blau-source-packages}"

"$APPLE_ROOT/bin/app-icon-tool.swift" validate

build() {
  local scheme="$1"
  local destination="$2"
  DISABLE_SWIFTLINT=1 xcodebuild build -quiet \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -destination "$destination" \
    -derivedDataPath "$DERIVED_ROOT/$scheme" \
    -clonedSourcePackagesDirPath "$PACKAGES" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
}

build Pilot "platform=macOS,arch=$(uname -m)"
build Copilot "generic/platform=iOS Simulator"
build Plotter "generic/platform=iOS Simulator"
