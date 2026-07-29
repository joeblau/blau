#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_PACKAGE_ROOT="$APPLE_ROOT/Packages/ChromiumKit"
PACKAGE_ROOT="$DEFAULT_PACKAGE_ROOT"

fail() {
  printf 'ChromiumKit installation verification error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'Usage: verify-installed-chromiumkit.sh [--package-root <directory>]' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package-root)
      [[ $# -ge 2 ]] || usage
      PACKAGE_ROOT="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

for tool in cmp find jq shasum stat; do
  command -v "$tool" >/dev/null 2>&1 ||
    fail "missing required tool: $tool"
done

[[ -d "$PACKAGE_ROOT" ]] || fail "package root does not exist: $PACKAGE_ROOT"
PACKAGE_ROOT="$(cd "$PACKAGE_ROOT" && pwd -P)"
MANIFEST="${BLAU_CHROMIUM_MANIFEST:-$PACKAGE_ROOT/cef-artifacts.json}"
[[ -f "$MANIFEST" ]] || fail "artifact lock is missing"
artifact_root_relative="$(jq -er \
  '.artifactLayout.root |
   select(type == "string" and . == "Artifacts/CEF")' \
  "$MANIFEST")" || fail "artifact root is not the managed CEF directory"
artifact_root="$PACKAGE_ROOT/$artifact_root_relative"
installed_lock="$artifact_root/cef-artifacts.json"
receipt_name="$(jq -er \
  '.artifactLayout.receipt |
   select(type == "string" and
     startswith("Artifacts/CEF/") and
     (contains("..") | not)) |
   ltrimstr("Artifacts/CEF/")' \
  "$MANIFEST")" || fail "artifact receipt path is unsafe"
receipt="$artifact_root/$receipt_name"

[[ -d "$artifact_root" ]] ||
  fail "pinned runtime is not installed; run update-chromiumkit-artifact.sh"
[[ -f "$installed_lock" ]] || fail "installed artifact lock is missing"
[[ -f "$receipt" ]] || fail "installation receipt is missing"
cmp -s "$MANIFEST" "$installed_lock" ||
  fail "installed artifact lock differs from the checked-in lock"

jq -e --slurpfile lock "$MANIFEST" '
  def expected_files:
    ($lock[0].artifactLayout.root + "/") as $prefix |
    [
      ($lock[0].artifactLayout.framework + "/Versions/A/"
        + $lock[0].artifactLayout.frameworkExecutable),
      ($lock[0].artifactLayout.headers + "/cef_app.h"),
      $lock[0].artifactLayout.wrapperLibrary,
      $lock[0].artifactLayout.license,
      $lock[0].artifactLayout.credits,
      ($lock[0].artifactLayout.root + "/cef-artifacts.json")
    ] |
    map(select(startswith($prefix)) | ltrimstr($prefix)) |
    sort;
  .schemaVersion == 1 and
  .releaseID == $lock[0].releaseID and
  .artifact == "ChromiumKitCEF.runtime.zip" and
  (.artifactBytes | type == "number" and . > 0 and floor == .) and
  (.artifactSHA256 |
    type == "string" and test("^[0-9a-f]{64}$")) and
  .cef == $lock[0].cef and
  .sourceArchives == $lock[0].sourceArchives and
  .architectures == $lock[0].artifactLayout.architectures and
  (.installedBytes | type == "number" and . > 0 and floor == .) and
  (.installedFiles | type == "object") and
  ((.installedFiles | keys | sort) == expected_files) and
  (.installedFiles |
    all(.[]; type == "string" and test("^[0-9a-f]{64}$"))) and
  ((.toolVersions | keys | sort) == ["cmake", "xcode", "zip"]) and
  (.toolVersions | all(.[]; type == "string" and length > 0))
' "$receipt" >/dev/null ||
  fail "installation receipt does not match the checked-in lock"

while IFS=$'\t' read -r relative expected_sha; do
  [[ -n "$relative" &&
     "$relative" != /* &&
     "$relative" != *\\* &&
     "/$relative/" != *"/../"* ]] ||
    fail "installation receipt contains an unsafe path: $relative"
  installed_file="$artifact_root/$relative"
  [[ -f "$installed_file" ]] ||
    fail "receipt file is missing: $relative"
  actual_sha="$(shasum -a 256 "$installed_file" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] ||
    fail "receipt hash differs for: $relative"
done < <(
  jq -r \
    '.installedFiles | to_entries[] | [.key, .value] | @tsv' \
    "$receipt"
)

actual_installed_bytes="$(find "$artifact_root" -type f \
  ! -path "$receipt" -exec stat -f '%z' {} + |
  awk '{ total += $1 } END { print total + 0 }')"
expected_installed_bytes="$(jq -r '.installedBytes' "$receipt")"
[[ "$actual_installed_bytes" == "$expected_installed_bytes" ]] ||
  fail "installed byte count differs: expected $expected_installed_bytes, got $actual_installed_bytes"

printf 'Verified pinned ChromiumKit installation at %s\n' "$artifact_root"
