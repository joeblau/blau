# blau

Three-app ecosystem + landing page.

## Apple Apps (Pilot macOS, Copilot iOS, Wingman watchOS)

```bash
cd apple
brew bundle
xcodegen generate
open blau.xcodeproj
```

## Web (blau.app)

The JS workspaces under `workers/` are orchestrated from the repo root with
[Turborepo](https://turbo.build/repo) + Bun workspaces, so tasks run from the
root with caching:

```bash
bun install        # resolves every workers/* workspace
bun run dev        # turbo run dev   — Astro dev server (+ rendezvous)
bun run build      # turbo run build — cached static build
```

Or run a single workspace directly, e.g. `cd workers/web && bun run dev`.
