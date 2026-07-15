#!/usr/bin/env bash
set -euo pipefail

VERSION="2.45.4"
ARCHIVE_SHA256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"
CACHE_ROOT="${XDG_CACHE_HOME:-${HOME}/Library/Caches}/blau/xcodegen/${VERSION}"
XCODEGEN="${CACHE_ROOT}/xcodegen/bin/xcodegen"

if [[ ! -x "$XCODEGEN" ]]; then
  mkdir -p "$CACHE_ROOT"
  archive="$(mktemp -t blau-xcodegen.XXXXXX.zip)"
  trap 'rm -f "${archive:-}"' EXIT
  curl -fsSL "https://github.com/yonaskolb/XcodeGen/releases/download/${VERSION}/xcodegen.zip" -o "$archive"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual" == "$ARCHIVE_SHA256" ]] || {
    echo "XcodeGen checksum mismatch" >&2
    exit 1
  }
  unzip -qo "$archive" -d "$CACHE_ROOT"
fi

exec "$XCODEGEN" "$@"
