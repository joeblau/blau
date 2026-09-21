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
- `CLOUDFLARE_ACCOUNT_ID` secret or variable: set this if the token has access to
  multiple accounts. Wrangler automatically selects the account when only one
  is available.

Secrets from another repository are not automatically inherited. Never commit
credentials or local `.env` / `.dev.vars` files.

For a local deployment with Cloudflare credentials:

```bash
bun run build
bunx --no-install wrangler whoami
bun run deploy
```

## Routing

The `blau-app` Worker handles `blau.app/*` in front of the existing `blau-web`
Custom Domain. `/` and `/_next/` use OpenNext. `/made` and `/made/` serve the
Astro homepage through the `MADE_SITE` service binding; all other paths go to
that Worker unchanged. Keep `blau-web` deployed in the same Cloudflare account.
Its source remains in [joeblau/made](https://github.com/joeblau/made).

To preview `/made` locally, also run that repository's Astro Worker using
Wrangler on another port. The service binding connects automatically.

The app follows the [OpenNext Cloudflare guide](https://opennext.js.org/cloudflare/get-started).
