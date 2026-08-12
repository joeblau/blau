# Apple releases

The `Apple Release` GitHub Actions workflow turns a `vMAJOR.MINOR.PATCH` tag
on `main` into one coordinated Apple release:

- Pilot is built as a universal Chromium-enabled macOS app, signed with
  Developer ID, notarized, stapled, and attached to a GitHub Release as a ZIP
  with a SHA-256 checksum. The release also carries a Sparkle appcast
  (`appcast.xml`) whose enclosure is EdDSA-signed, so installed copies
  self-update from `releases/latest/download/appcast.xml`.
- Copilot, including Wingman, is uploaded to App Store Connect for TestFlight.
- Plotter, including PlotterWidgets, is uploaded to App Store Connect for
  TestFlight.
- The public GitHub Release is created only after the notarized macOS artifact
  and both TestFlight uploads succeed.

The semantic version comes from the tag. `GITHUB_RUN_NUMBER` and
`GITHUB_RUN_ATTEMPT` form the Apple build number, so retrying a workflow does
not reuse a build number that App Store Connect may already have accepted.

## One-time Apple setup

Create the following identifiers and capabilities in Certificates,
Identifiers & Profiles before the first release:

- `app.blau.copilot`
- `app.blau.copilot.watchkitapp`
- `app.blau.plotter`
- `app.blau.plotter.widgets`
- the `group.app.blau.plotter` App Group, assigned to Plotter and
  PlotterWidgets

Create App Store Connect app records for Copilot (`app.blau.copilot`) and
Plotter (`app.blau.plotter`). Apple must know those top-level apps before a CI
upload can be associated with TestFlight.

Create a team App Store Connect API key under **Users and Access >
Integrations > Team Keys**. Use an Admin key so headless Xcode automatic
signing, provisioning, cloud-managed distribution signing, TestFlight upload,
and `notarytool` are authorized. The private `.p8` file can only be downloaded
once. Individual API keys do not support the provisioning endpoints or
`notarytool`, so they cannot replace the team key in this workflow.

Create a **Developer ID Application** certificate for Pilot. Export the
certificate and its private key from Keychain Access as a password-protected
`.p12`. An Apple Distribution certificate is not stored in GitHub: Xcode uses
the team API key and Apple's cloud-managed distribution signing for the App
Store uploads.

Sparkle updates are signed with an EdDSA key pair that lives in the
maintainer's login keychain under the `blau` account (created with
`generate_keys` from the pinned Sparkle release; the matching public key is
baked into Pilot's `Info.plist` as `SUPublicEDKey`). Export the private key
and store it as the CI secret:

```bash
./bin/generate_keys --account blau -x /tmp/sparkle-blau-private-key
gh secret set SPARKLE_PRIVATE_KEY --env apple-release \
  --body "$(cat /tmp/sparkle-blau-private-key)"
rm -P /tmp/sparkle-blau-private-key
```

Losing the private key means shipping a new public key with the next release
and leaving older installs unable to verify updates, so keep a copy in the
team password manager.

Apple references:

- [Create an App Store Connect API key](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)
- [Create a Developer ID certificate](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Upload builds to App Store Connect](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)

## GitHub environment and secrets

Create an `apple-release` GitHub environment. A required reviewer is
recommended because a matching tag uploads binaries to Apple and publishes a
download. Store these environment secrets:

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | The 10-character Apple Developer team ID. |
| `APP_STORE_CONNECT_KEY_ID` | The team API key ID. |
| `APP_STORE_CONNECT_ISSUER_ID` | The team API issuer UUID. |
| `APP_STORE_CONNECT_PRIVATE_KEY_P8_BASE64` | Base64-encoded contents of the downloaded `AuthKey_*.p8`. |
| `MACOS_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate and private key. |
| `MACOS_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12`. |
| `MACOS_SIGNING_IDENTITY` | Full identity, for example `Developer ID Application: Example, Inc. (TEAMID1234)`. |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key for signing Sparkle update enclosures (see above). |

Encode the two files without introducing line wrapping:

```bash
base64 -i AuthKey_KEYID.p8 | pbcopy
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Use a GitHub ruleset to restrict creation and deletion of tags matching `v*`
to release maintainers. The workflow also refuses tags whose target commit is
not reachable from `main`.

## Cut a release

Run the normal pull-request CI on the intended commit, merge it to `main`, and
then push the version tag:

```bash
git switch main
git pull --ff-only
git tag -s v1.2.3 -m "blau 1.2.3"
git push origin v1.2.3
```

The first Pilot release for a pinned Chromium version reproduces the verified
runtime from its locked upstream archives. Later releases reuse the immutable
`chromiumkit-<release-id>` GitHub Release when one exists and verify its
release attestation and asset bytes before installation.

Successful upload makes each mobile build appear in App Store Connect after
Apple finishes processing it. Assigning tester groups, completing export
compliance, submitting an external beta for review, and promoting a build to
the App Store remain explicit App Store Connect operations.

Do not move or reuse a release tag. If a release needs another binary, make a
new version tag. A workflow retry receives a new build number automatically.

Sparkle reads the feed from `releases/latest/download/appcast.xml`, so the
"latest" badge must stay on app releases: this workflow publishes with
`--latest=true`, the ChromiumKit workflow publishes with `--latest=false`, and
any component release cut by hand (e.g. GhosttyKit) must not take the badge.
