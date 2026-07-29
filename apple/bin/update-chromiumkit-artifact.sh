#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_PACKAGE_ROOT="$APPLE_ROOT/Packages/ChromiumKit"
PACKAGE_ROOT="$DEFAULT_PACKAGE_ROOT"
PACKAGER="$APPLE_ROOT/bin/package-chromiumkit.sh"
DESTINATION=""
work="$(mktemp -d "${TMPDIR:-/tmp}/blau-chromiumkit-install.XXXXXX")"
candidate_container=""
rollback_directory=""
had_previous=0
install_committed=0

cleanup() {
  local status=$?
  if [[ "$install_committed" == 0 &&
        -n "$DESTINATION" &&
        -n "$rollback_directory" ]]; then
    if [[ "$had_previous" == 1 && -d "$rollback_directory" ]]; then
      if [[ -e "$DESTINATION" ]]; then
        rm -rf "$DESTINATION"
      fi
      mv "$rollback_directory" "$DESTINATION" || {
        printf 'ChromiumKit installer could not restore %s\n' \
          "$DESTINATION" >&2
        status=1
      }
    elif [[ "$had_previous" == 0 && -e "$DESTINATION" ]]; then
      rm -rf "$DESTINATION"
    fi
  fi
  [[ -z "$candidate_container" ]] || rm -rf "$candidate_container"
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

usage() {
  printf '%s\n' \
    'Usage: update-chromiumkit-artifact.sh [--release-directory <directory>] [--package-root <directory>]' >&2
  exit 2
}

release_directory=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-directory)
      [[ $# -ge 2 ]] || usage
      release_directory="$2"
      shift 2
      ;;
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

[[ -d "$PACKAGE_ROOT" ]] || {
  printf 'ChromiumKit package root does not exist: %s\n' \
    "$PACKAGE_ROOT" >&2
  exit 1
}
PACKAGE_ROOT="$(cd "$PACKAGE_ROOT" && pwd -P)"
if [[ "$PACKAGE_ROOT" != "$DEFAULT_PACKAGE_ROOT" &&
      -z "$release_directory" ]]; then
  printf '%s\n' \
    'A non-default package root requires --release-directory' >&2
  exit 1
fi
MANIFEST="$PACKAGE_ROOT/cef-artifacts.json"
[[ -f "$MANIFEST" ]] || {
  printf 'ChromiumKit artifact lock does not exist: %s\n' "$MANIFEST" >&2
  exit 1
}
artifact_root="$(jq -er \
  '.artifactLayout.root |
   select(type == "string" and startswith("Artifacts/") and
     (contains("..") | not))' "$MANIFEST")" || {
  printf 'ChromiumKit artifact lock has an unsafe artifact root\n' >&2
  exit 1
}
DESTINATION="$PACKAGE_ROOT/$artifact_root"

if [[ -n "$release_directory" ]]; then
  [[ -d "$release_directory" ]] || {
    printf 'ChromiumKit release directory does not exist: %s\n' \
      "$release_directory" >&2
    exit 1
  }
  release_directory="$(cd "$release_directory" && pwd)"
else
  bash "$PACKAGER" build "$work/release"
  release_directory="$work/release"
fi

(
  cd "$release_directory"
  shasum -a 256 -c ChromiumKitCEF.checksums.txt
)
runtime_sha="$(shasum -a 256 \
  "$release_directory/ChromiumKitCEF.runtime.zip" | awk '{print $1}')"
runtime_bytes="$(stat -f '%z' \
  "$release_directory/ChromiumKitCEF.runtime.zip")"
jq -e --arg runtime_sha "$runtime_sha" \
  --argjson runtime_bytes "$runtime_bytes" \
  --slurpfile lock "$MANIFEST" \
  '.schemaVersion == 1 and
   .releaseID == $lock[0].releaseID and
   .artifact == "ChromiumKitCEF.runtime.zip" and
   .artifactSHA256 == $runtime_sha and
   .artifactBytes == $runtime_bytes and
   .cef == $lock[0].cef and
   .sourceArchives == $lock[0].sourceArchives and
   .architectures == $lock[0].artifactLayout.architectures and
   (.installedBytes |
     type == "number" and . > 0 and floor == .) and
   (.installedFiles | type == "object" and length == 6)' \
  "$release_directory/ChromiumKitCEF.release.json" >/dev/null
unzip -Z1 "$release_directory/ChromiumKitCEF.runtime.zip" >/dev/null
while IFS= read -r entry; do
  [[ "$entry" == "CEF/" || "$entry" == CEF/* ]] || {
    printf 'ChromiumKit archive contains an unsafe path: %s\n' \
      "$entry" >&2
    exit 1
  }
  [[ "$entry" != *\\* && "/$entry/" != *"/../"* ]] || {
    printf 'ChromiumKit archive contains an unsafe path: %s\n' \
      "$entry" >&2
    exit 1
  }
done < <(unzip -Z1 "$release_directory/ChromiumKitCEF.runtime.zip")
destination_parent="$(dirname "$DESTINATION")"
mkdir -p "$destination_parent"
candidate_container="$(mktemp -d \
  "$destination_parent/.CEF-candidate.XXXXXX")"
unzip -q "$release_directory/ChromiumKitCEF.runtime.zip" \
  -d "$candidate_container"
candidate="$candidate_container/CEF"
[[ -d "$candidate/Chromium Embedded Framework.framework" &&
   -d "$candidate/include" &&
   -f "$candidate/lib/libcef_dll_wrapper.a" &&
   -f "$candidate/LICENSE.txt" &&
   -f "$candidate/CREDITS.html" &&
   -f "$candidate/cef-artifacts.json" ]] || {
  printf 'ChromiumKit installer received an invalid runtime archive\n' >&2
  exit 1
}
while IFS= read -r -d '' link; do
  target="$(readlink "$link")"
  [[ -n "$target" &&
     "$target" != /* &&
     "$target" != *\\* &&
     "/$target/" != *"/../"* ]] || {
    printf 'ChromiumKit archive contains an unsafe symlink: %s\n' \
      "$link" >&2
    exit 1
  }
done < <(find "$candidate" -type l -print0)
cmp "$MANIFEST" "$candidate/cef-artifacts.json"
while IFS=$'\t' read -r relative expected_sha; do
  [[ "$relative" != /* && "$relative" != *".."* ]] || {
    printf 'ChromiumKit receipt contains an unsafe path: %s\n' "$relative" >&2
    exit 1
  }
  actual_sha="$(shasum -a 256 "$candidate/$relative" |
    awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || {
    printf 'ChromiumKit installed-file hash differs: %s\n' "$relative" >&2
    exit 1
  }
done < <(jq -r '.installedFiles | to_entries[] | [.key, .value] | @tsv' \
  "$release_directory/ChromiumKitCEF.release.json")
actual_installed_bytes="$(find "$candidate" -type f -exec stat -f '%z' {} + |
  awk '{ total += $1 } END { print total + 0 }')"
expected_installed_bytes="$(jq -r '.installedBytes' \
  "$release_directory/ChromiumKitCEF.release.json")"
[[ "$actual_installed_bytes" == "$expected_installed_bytes" ]] || {
  printf 'ChromiumKit installed byte count differs: expected %s, got %s\n' \
    "$expected_installed_bytes" "$actual_installed_bytes" >&2
  exit 1
}

cp "$release_directory/ChromiumKitCEF.release.json" \
  "$candidate/ChromiumKitCEF.release.json"

expected="$PACKAGE_ROOT/Artifacts/CEF"
[[ "$DESTINATION" == "$expected" ]] || {
  printf 'Refusing to replace unexpected destination: %s\n' "$DESTINATION" >&2
  exit 1
}
previous_compressed=0
previous_installed=0
if [[ -f "$DESTINATION/ChromiumKitCEF.release.json" ]]; then
  previous_compressed="$(jq -er \
    '.artifactBytes |
     select(type == "number" and . >= 0 and floor == .)' \
    "$DESTINATION/ChromiumKitCEF.release.json" 2>/dev/null || printf '0')"
  previous_installed="$(jq -er \
    '.installedBytes |
     select(type == "number" and . >= 0 and floor == .)' \
    "$DESTINATION/ChromiumKitCEF.release.json" 2>/dev/null || printf '0')"
fi
new_compressed="$(jq -r '.artifactBytes' \
  "$release_directory/ChromiumKitCEF.release.json")"
new_installed="$(jq -r '.installedBytes' \
  "$release_directory/ChromiumKitCEF.release.json")"
mkdir -p "$PACKAGE_ROOT/Artifacts"
rollback_directory="$(mktemp -d \
  "$destination_parent/.CEF-rollback.XXXXXX")"
rmdir "$rollback_directory"
if [[ -e "$DESTINATION" ]]; then
  had_previous=1
  mv "$DESTINATION" "$rollback_directory"
fi
mv "$candidate" "$DESTINATION"
cmp "$MANIFEST" "$DESTINATION/cef-artifacts.json"
cmp "$release_directory/ChromiumKitCEF.release.json" \
  "$DESTINATION/ChromiumKitCEF.release.json"
install_committed=1
if [[ "$had_previous" == 1 ]]; then
  rm -rf "$rollback_directory"
fi
rollback_directory=""
printf 'Installed pinned Chromium runtime at %s\n' "$DESTINATION"
printf 'Compressed bytes: %s (change %+d)\n' \
  "$new_compressed" "$((new_compressed - previous_compressed))"
printf 'Installed bytes: %s (change %+d)\n' \
  "$new_installed" "$((new_installed - previous_installed))"
