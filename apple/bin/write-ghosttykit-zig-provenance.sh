#!/usr/bin/env bash
set -euo pipefail

output="${1:?Usage: write-ghosttykit-zig-provenance.sh <output.json>}"
formula_revision="1"
formula_git_revision="66277812877bd6b470da86a59208ef0be903ca0c"
formula_sha256="91e0a69da295d32f65938042255de5199ebc83602d5b87a517acad1bb3ec9829"
source_url="https://ziglang.org/download/0.15.2/zig-0.15.2.tar.xz"
source_sha256="d9b30c7aa983fcff5eed2084d54ae83eaafe7ff3a84d8fb754d854165a6e521c"

for tool in brew jq shasum zig; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

[[ "$(zig version)" == "0.15.2" ]]
zig_prefix="$(brew --prefix blau/pinned/zig)"
zig_executable="$(command -v zig)"
[[ "$zig_executable" == "$zig_prefix/bin/zig" ]]
[[ "$(brew list --versions blau/pinned/zig)" == "zig 0.15.2_1" ]]

work="$(mktemp -d -t blau-zig-provenance.XXXXXX)"
trap 'rm -rf "$work"' EXIT

canonical_receipt() {
  local formula="$1"
  local prefix
  local receipt
  local canonical
  prefix="$(brew --prefix "$formula")"
  receipt="$prefix/INSTALL_RECEIPT.json"
  [[ -f "$receipt" ]]
  canonical="$(mktemp "$work/receipt.XXXXXX")"
  jq -cS \
    --arg formula "$formula" \
    --arg installed "$(brew list --versions "$formula")" \
    '{
      formula: $formula,
      installed: $installed,
      receipt: {
        source: (.source | {
          spec,
          versions,
          tap
        }),
        arch,
        compiler,
        built_as_bottle,
        poured_from_bottle,
        built_on,
        runtime_dependencies: [
          .runtime_dependencies[] | {
            full_name,
            pkg_version,
            bottle_rebuild
          }
        ]
      }
    }' "$receipt" > "$canonical"
  jq -cS \
    --arg canonical_sha "$(shasum -a 256 "$canonical" | awk '{print $1}')" \
    '. + {canonicalReceiptSHA256: $canonical_sha}' \
    "$canonical"
}

canonical_receipt blau/pinned/zig > "$work/zig-receipt.json"
for dependency in cmake llvm@20 lld@20 zstd; do
  canonical_receipt "$dependency"
done > "$work/dependencies.jsonl"
jq -sS . "$work/dependencies.jsonl" > "$work/dependencies.json"

mkdir -p "$(dirname "$output")"
jq -nS \
  --arg formula_revision "$formula_revision" \
  --arg formula_git_revision "$formula_git_revision" \
  --arg formula_sha256 "$formula_sha256" \
  --arg source_url "$source_url" \
  --arg source_sha256 "$source_sha256" \
  --arg executable_sha "$(shasum -a 256 "$zig_executable" | awk '{print $1}')" \
  --arg homebrew_version "$(brew --version | head -1)" \
  --slurpfile zig_receipt "$work/zig-receipt.json" \
  --slurpfile dependencies "$work/dependencies.json" \
  '{
    schemaVersion: 1,
    distribution: "Homebrew source build",
    version: "0.15.2_1",
    formulaRevision: $formula_revision,
    formulaGitRevision: $formula_git_revision,
    formulaSHA256: $formula_sha256,
    sourceURL: $source_url,
    sourceSHA256: $source_sha256,
    executableSHA256: $executable_sha,
    homebrewVersion: $homebrew_version,
    zigReceipt: $zig_receipt[0],
    dependencyReceipts: $dependencies[0]
  }' > "$output"

jq -e . "$output" >/dev/null
