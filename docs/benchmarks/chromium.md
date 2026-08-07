# Chromium performance baselines

This document records the performance budgets and the latest measured
baselines for the Chromium runtime embedded by Pilot. Budgets are pinned in
`apple/Packages/ChromiumKit/performance-budgets.json`; measurements come from
the reproducibility validation round for the current release ID. The
`release-artifacts/` directory is untracked local output, so the measured
numbers are recorded here rather than linked.

Release ID: `150.0.14-g7c1aa68-chromium-150.0.7871.129-blau.1`

## Artifact size

Measured from the release receipt (`ChromiumKitCEF.release.json`) produced by
the latest two-build reproducibility validation, in which both builds emitted
byte-identical assets:

| Metric | Budget ceiling | Measured | Headroom |
| --- | ---: | ---: | ---: |
| Compressed runtime archive | 265,000,000 bytes | 252,206,279 bytes | 12,793,721 bytes |
| Installed runtime | 625,000,000 bytes | 611,266,828 bytes | 13,733,172 bytes |

The measured archive SHA-256 is
`91cc1bfff3f0c2a688d01583e33962ec9f49475cf2ef0baac03805256385b418`. The
receipt also records tool provenance for reproducibility: Xcode 26.6 (build
17F113), cmake 4.4.0, and Info-ZIP zip.

## Runtime budgets

Per-architecture ceilings from `performance-budgets.json`:

| Metric | arm64 | x86_64 |
| --- | ---: | ---: |
| Startup | 5 s | 40 s |
| First navigation | 2 s | 2 s |
| Helper cleanup after shutdown | 5 s | 5 s |
| Idle process-tree CPU | 35 % | 35 % |
| Idle Pilot-watchdog message-pump turns | 12 | 12 |
| Resident memory | 1,250,000,000 bytes | 1,250,000,000 bytes |

The x86_64 startup ceiling includes cold Rosetta translation. The watchdog
turn budget rejects a regression to high-frequency Pilot-owned message-pump
polling even when host CPU stays under its ceiling; CEF-requested turns are
diagnostic and do not count against the limit. CPU is calculated from
cumulative process time across two snapshots, not an instantaneous `ps`
percentage.

## Enforcement

- Size budgets are enforced at packaging time by
  `apple/bin/package-chromiumkit.sh`, which fails the build when the emitted
  archive exceeds `maximumCompressedBytes` or the installed payload exceeds
  `maximumInstalledBytes`.
- Runtime budgets are asserted by `ChromiumRealEngineSmokeTests`, run through
  `apple/bin/test-chromium-runtime.sh` against the assembled, signed
  application for each architecture.
- The protected `ChromiumKit Signed Release` workflow runs the same probe
  after importing its signing identity and installing the verified runtime,
  so a budget regression blocks notarization and publication.
- `ChromiumArtifactManifestTests` additionally pins the budget values and
  requires them to match the checked-in lock's release ID, so a budget change
  cannot land silently.
- Any budget change therefore requires an explicit reviewed diff alongside a
  CEF update, per the
  [Chromium update and emergency runbook](../chromium-update-runbook.md).
