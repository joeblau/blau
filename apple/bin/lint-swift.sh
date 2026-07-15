#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="0.63.1"
ARCHIVE_SHA256="0e6369741b694b701e9bd4e4fe9b408a5946d4bb076b79ea6ec2bce428475739"
CACHE_ROOT="${XDG_CACHE_HOME:-${HOME}/Library/Caches}/blau/swiftlint/${VERSION}"
SWIFTLINT="${CACHE_ROOT}/swiftlint"
BASELINE="apple/.swiftlint-baseline.json"
MODE="changed"
BASE="${SWIFTLINT_BASE:-origin/main}"

usage() {
  echo "Usage: apple/bin/lint-swift.sh [--all | --changed [git-base]]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) MODE="all"; shift ;;
    --changed)
      MODE="changed"
      if [[ $# -gt 1 && "$2" != -* ]]; then BASE="$2"; shift 2; else shift; fi
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if command -v swiftlint >/dev/null 2>&1 && [[ "$(swiftlint version)" == "$VERSION" ]]; then
  SWIFTLINT="$(command -v swiftlint)"
elif [[ ! -x "$SWIFTLINT" ]]; then
  command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
  command -v unzip >/dev/null || { echo "unzip is required" >&2; exit 1; }
  mkdir -p "$CACHE_ROOT"
  archive="$(mktemp -t blau-swiftlint.XXXXXX.zip)"
  trap 'rm -f "${archive:-}"' EXIT
  curl -fsSL "https://github.com/realm/SwiftLint/releases/download/${VERSION}/portable_swiftlint.zip" -o "$archive"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual" == "$ARCHIVE_SHA256" ]] || { echo "SwiftLint checksum mismatch" >&2; exit 1; }
  unzip -qo "$archive" swiftlint -d "$CACHE_ROOT"
  chmod +x "$SWIFTLINT"
fi

cd "$ROOT"
if [[ "$MODE" == "all" ]]; then
  exec "$SWIFTLINT" lint --strict --config apple/.swiftlint.yml --baseline "$BASELINE" apple/Sources apple/Tests
fi

git rev-parse --verify "$BASE" >/dev/null 2>&1 || {
  echo "Git base '$BASE' is unavailable; fetch it or pass --all." >&2
  exit 2
}
files=()
while IFS= read -r file; do files+=("$file"); done < <(
  git diff --name-only --diff-filter=ACMR "${BASE}...HEAD" -- apple/Sources apple/Tests \
    | rg '\.swift$' || true
)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "No changed Swift files to lint."
  exit 0
fi
exec "$SWIFTLINT" lint --strict --config apple/.swiftlint.yml --baseline "$BASELINE" "${files[@]}"
