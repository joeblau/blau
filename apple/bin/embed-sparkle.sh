#!/usr/bin/env bash
set -euo pipefail

# Signs Sparkle.framework inside the built app, inside-out with hardened
# runtime, no entitlements, and the same identity/timestamp policy as
# assemble-chromium-runtime.sh. Sparkle's SwiftPM product is a binary
# xcframework: XcodeGen's Embed Frameworks phase cannot copy it
# ("Sparkle-product" build error), so Xcode's implicit copy for linked binary
# products embeds it — with upstream's ad-hoc nested signatures, which the
# release validator rejects (nested code must match Pilot's team). This phase
# re-signs the copied framework in place; it never deletes the framework, so
# it cannot race Xcode's copy/sign-on-copy into a corrupt bundle, and its
# declared build-phase inputs order it after those steps. If the implicit
# copy has not run (or left a broken framework), the framework is copied from
# the materialized product here instead. Falls back to ad-hoc signing when
# the build disables code signing (CI test lanes).

fail() {
  printf 'Sparkle embed error: %s\n' "$*" >&2
  exit 1
}

for tool in codesign ditto file find; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

APP="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
[[ -d "$APP/Contents" ]] || fail "invalid app bundle: $APP"
source_framework="${BUILT_PRODUCTS_DIR:?}/Sparkle.framework"
[[ -d "$source_framework" ]] ||
  fail "Sparkle.framework was not materialized at $source_framework"

frameworks="$APP/Contents/Frameworks"
destination="$frameworks/Sparkle.framework"
if [[ ! -L "$destination/Versions/Current" ]]; then
  mkdir -p "$frameworks"
  rm -rf "$destination"
  ditto "$source_framework" "$destination"
fi

identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
timestamp_argument="--timestamp=none"
if [[ "${BLAU_CHROMIUM_CODESIGN_TIMESTAMP:-NO}" == "YES" ||
      "${ACTION:-}" == "install" ]]; then
  timestamp_argument="--timestamp"
fi

# Sign bare Mach-O payloads, then nested bundles (deepest first), then the
# framework itself, so every seal is created after the code it covers.
# --preserve-metadata=entitlements keeps upstream's entitlements through the
# re-sign: Autoupdate must keep its application-identifier entitlement (the
# release validator pins it exactly) and every other binary carries none.
while IFS= read -r binary; do
  if file "$binary" | grep -q 'Mach-O'; then
    codesign --force --sign "$identity" --options runtime \
      --preserve-metadata=entitlements "$timestamp_argument" "$binary"
  fi
done < <(find "$destination" -type f -print | LC_ALL=C sort)

while IFS= read -r bundle_path; do
  codesign --force --sign "$identity" --options runtime \
    --preserve-metadata=entitlements "$timestamp_argument" "$bundle_path"
done < <(find "$destination" \( -name '*.xpc' -o -name '*.app' \) -print |
  LC_ALL=C sort -r)

codesign --force --sign "$identity" --options runtime \
  --preserve-metadata=entitlements "$timestamp_argument" "$destination"

printf 'Signed Sparkle.framework in %s\n' "$APP"
