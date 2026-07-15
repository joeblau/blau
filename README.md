# blau

Three-app ecosystem + landing page.

## Apple Apps (Pilot macOS, Copilot iOS, Wingman watchOS)

```bash
cd apple
brew bundle
xcodegen generate
open blau.xcodeproj
```

### Apple verification

Run both unit-test schemes with deterministic host destinations from the
repository root:

```bash
apple/bin/test.sh all       # PilotTests on macOS, then SharedTests on iOS Simulator
apple/bin/test.sh pilot     # macOS suite only
apple/bin/test.sh shared    # iOS Simulator suite only
```

`IOS_SIMULATOR_UDID` can select a specific available iPhone simulator for the
shared suite. The scripts pin `Package.resolved`, disable code signing, and
disable the transitive SwiftLint build plugin so package-tool noise cannot hide
test failures.

Repository-owned Swift lint is pinned separately and uses a checked-in baseline:

```bash
apple/bin/lint-swift.sh --all
apple/bin/lint-swift.sh --changed origin/main
```

Suppress a rule only at the narrowest declaration or line, with a comment that
explains why. New code must not add entries to the baseline; tighten the
baseline as existing violations are fixed.

## Web (blau.app)

The JS workspaces under `workers/` are orchestrated from the repo root with
[Turborepo](https://turbo.build/repo) + Bun workspaces, so tasks run from the
root with caching:

```bash
bun install        # resolves every workers/* workspace
bun run dev        # turbo run dev   — Astro dev server (+ rendezvous)
bun run build      # turbo run build — cached static build
bun run ci         # lint, type/metadata checks, tests, builds, and audit
```

Or run a single workspace directly, e.g. `cd workers/web && bun run dev`.
Production deployment, rollback, security-header, and least-privilege token
details are in [`docs/operations.md`](docs/operations.md).

## Notes security boundary

Pilot Notes is a local plaintext scratchpad. Its `.env`-style value masking is
only a visual shoulder-surfing aid: it does not encrypt the note in SwiftData.
Locked values are redacted from note-tab titles and accessibility output, and a
value reaches the pasteboard only after an explicit copy action. Do not use
Notes as a password or secret manager.
