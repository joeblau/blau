# blau.app

A directory of developer tools, marketing tools, and entertainment, built with
Next.js, shadcn/ui, and Tailwind CSS. Bun and OpenNext deploy the site to
Cloudflare Workers.

## Development

Use Bun 1.3.14 and Node.js 22 or newer.

```bash
bun install --frozen-lockfile
bun run dev
```

Next.js serves the app at `http://localhost:3000`. To check the production
build in the Workers runtime:

```bash
bun run ci
bun run preview
```

## Deployment

[Deploy site to Cloudflare](.github/workflows/deploy.yml) runs on pushes to
`main` and through GitHub Actions → Run workflow. It installs the frozen Bun
lockfile, runs lint/type checks, builds OpenNext, audits dependencies, and
deploys the `blau-app` Worker.

Configure these GitHub Actions settings in this repository or its `production`
environment:

- `CLOUDFLARE_API_TOKEN` secret: a token with Workers Scripts: Write for the account
  containing the `blau.app` zone,
  plus Workers Routes: Write and Zone: Read restricted to `blau.app`.
- `CLOUDFLARE_ACCOUNT_ID` secret or variable, if set, must match the Joe Blau
  account in `wrangler.jsonc`: `2b04333c55d653550f69d1c732b92d98`.

Secrets from another repository are not automatically inherited. Never commit
credentials or local `.env` / `.dev.vars` files.

For a local deployment with Cloudflare credentials:

```bash
bun run build
bunx --no-install wrangler whoami
bun run deploy
```

## Routing

`blau-app` handles `blau.app/*`. The homepage and global `/_next/*` namespace
stay with this Next.js app. Each mount and all paths beneath it forward the
original request through an HTTP service binding:

| Path | Worker |
| --- | --- |
| `/made` | `blau-made` |
| `/previral` | `blau-previral` |
| `/shotreel` | `blau-shortreel` |
| `/stint` | `blau-stint` |
| `/stream` | `blau-stream` |

Matches require the `blau.app` hostname and a complete path segment. Other
paths retain the existing MADE fallback. The `rendezvous.blau.app` service
keeps its existing hostname and is not mounted here.

Each child app is built for its prefix. Deploy child Workers before deploying
router changes. See [routing and verification](docs/routing.md) for the local
preview setup, companion changes, and rollout checks.

`bun run test` runs router tests as part of CI. `bun run test:apps` checks all
five mounted apps against a connected preview (or `PREVIEW_URL=https://blau.app`).
`bun run test:mount` retains the detailed ShortReel build-artifact check.

The app follows the [OpenNext Cloudflare guide](https://opennext.js.org/cloudflare/get-started).
