#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$APPLE_ROOT/Packages/ChromiumKit/cef-artifacts.json"
CEF_INDEX_URL="https://cef-builds.spotifycdn.com/index.json"
CHROME_HISTORY_URL="https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions?page_size=1"
work="$(mktemp -d "${TMPDIR:-/tmp}/blau-chromiumkit-support.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'ChromiumKit support gate error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'Usage: verify-chromiumkit-support.sh [--cef-index <file> --chrome-history <file>]' >&2
  exit 2
}

cef_index=""
chrome_history=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cef-index)
      [[ $# -ge 2 ]] || usage
      cef_index="$2"
      shift 2
      ;;
    --chrome-history)
      [[ $# -ge 2 ]] || usage
      chrome_history="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done
if [[ (-n "$cef_index" && -z "$chrome_history") ||
      (-z "$cef_index" && -n "$chrome_history") ]]; then
  usage
fi

command -v jq >/dev/null 2>&1 || fail "missing required tool: jq"
if [[ -z "$cef_index" ]]; then
  command -v curl >/dev/null 2>&1 || fail "missing required tool: curl"
  cef_index="$work/cef-index.json"
  chrome_history="$work/chrome-history.json"
  curl --fail --silent --show-error --location --max-time 30 \
    "$CEF_INDEX_URL" > "$cef_index"
  curl --fail --silent --show-error --location --max-time 30 \
    "$CHROME_HISTORY_URL" > "$chrome_history"
fi
[[ -f "$cef_index" && -f "$chrome_history" ]] ||
  fail "support inputs do not exist"

read_cef_field() {
  local platform="$1"
  local field="$2"
  # "Latest" means the highest Chromium version, not the most recently
  # uploaded build: backfilled legacy-branch builds (which may also lack
  # sandbox_compat) carry newer last_modified timestamps.
  local value
  value="$(jq -er --arg platform "$platform" --arg field "$field" '
    .[$platform].versions
    | map(select(
        .channel == "stable" and
        any(.files[]; .type == "minimal")
      ))
    | sort_by(.chromium_version | split(".") | map(tonumber))
    | last
    | .[$field]
  ' "$cef_index")" ||
    fail "CEF index is missing $field for the latest stable $platform build"
  printf '%s' "$value"
}

pinned_cef="$(jq -er '.cef.version' "$MANIFEST")"
pinned_chromium="$(jq -er \
  '.cef.version | capture("\\+chromium-(?<version>[0-9.]+)$").version' \
  "$MANIFEST")"
pinned_sandbox="$(jq -er '.cef.sandboxCompatibilityCommit' "$MANIFEST")"
arm_cef="$(read_cef_field macosarm64 cef_version)"
x86_cef="$(read_cef_field macosx64 cef_version)"
arm_chromium="$(read_cef_field macosarm64 chromium_version)"
x86_chromium="$(read_cef_field macosx64 chromium_version)"
arm_sandbox="$(read_cef_field macosarm64 sandbox_compat)"
x86_sandbox="$(read_cef_field macosx64 sandbox_compat)"
chrome_stable="$(jq -er '.versions | first | .version' "$chrome_history")"

[[ "$arm_cef" == "$x86_cef" &&
   "$arm_chromium" == "$x86_chromium" &&
   "$arm_sandbox" == "$x86_sandbox" ]] ||
  fail "latest stable CEF differs between macOS architectures"
[[ "$pinned_cef" == "$arm_cef" &&
   "$pinned_chromium" == "$arm_chromium" &&
   "$pinned_sandbox" == "$arm_sandbox" ]] ||
  fail "the lock is not the latest matching stable macOS CEF build (pinned $pinned_cef; available $arm_cef)"
[[ "$pinned_chromium" == "$chrome_stable" ]] ||
  fail "stable Chrome has advanced beyond the CEF runtime (pinned $pinned_chromium; stable $chrome_stable)"

printf 'ChromiumKit support gate passed: CEF %s / Chromium %s\n' \
  "$pinned_cef" "$pinned_chromium"
