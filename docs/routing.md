# Application routing

The `applications` registry in `worker.ts` matches `blau.app` and complete path
segments before the host application and existing MADE fallback. It forwards
the original request through a service binding and streams the response.

| Mount | Binding | Worker | Source checkout |
| --- | --- | --- | --- |
| `/made` | `MADE_SITE` | `blau-made` | `../made/workers/web` |
| `/previral` | `PREVIRAL_SITE` | `blau-previral` | `../previral/workers/web` |
| `/shotreel` | `WEB_SHORTREEL` | `blau-shortreel` | `../shortreel/workers/web` |
| `/stint` | `STINT_SITE` | `blau-stint` | `../stint/workers` |
| `/stream` | `STREAM_SITE` | `blau-stream` | `../stream/workers/web` |

The `/shotreel` spelling is intentional. Lookalike paths such as `/stints` or
`/stream-other` do not match. `/` and global `/_next/*` remain with this Next.js
app. Other paths/hosts retain the MADE fallback. `rendezvous.blau.app` remains
separate, with no route changes here.

## Child applications

Each Next.js child sets `basePath` to its mount and canonical metadata to
`https://blau.app` plus that mount. Public image URLs include the prefix.
`assets.run_worker_first: true` enables OpenNext's asset resolver using the
child's `ASSETS` binding. Existing self-reference bindings are retained.
Stint serves its local images unoptimized.

OpenNext emits `.open-next/assets/<mount>/`. Each `build:worker` command moves
`_headers` to the asset root so Wrangler consumes its cache rules. Use this
command before preview/deploy, rather than the adapter build alone. MADE uses
its existing Astro `/made` base and staged `.worker-assets/made` directory.
Redirects keep the browser origin and query. Next.js apps use no trailing slash;
MADE retains its Astro/static-assets convention.

## Deployment

The router and all five children use the verified Joe Blau account
`2b04333c55d653550f69d1c732b92d98`. The existing router name `blau-app` and
`blau.app/*` route are retained. Use the default Wrangler environment; the
GitHub environment named `production` is not a Wrangler environment.
Any account environment-variable override must agree.

Build/check and deploy changed children first, then run `bun run ci` and
`bun run deploy` here. Verify the live site with:

```sh
PREVIEW_URL=https://blau.app bun run test:apps
```

## Connected local preview

Build the apps first. Run each Worker in a separate terminal using the same
isolated `WRANGLER_REGISTRY_PATH`. This avoids conflicts with existing sessions
and the asset-storage collision in Wrangler 4.135.0's multiple-config mode.
From this repository, use `bunx --no-install wrangler dev --local` with:

| Configuration | Port | Inspector port |
| --- | --- | --- |
| `wrangler.jsonc` | 8810 | 9250 |
| `../shortreel/workers/web/wrangler.jsonc` | 8811 | 9251 |
| `../previral/workers/web/wrangler.jsonc` | 8812 | 9252 |
| `../stint/workers/wrangler.jsonc` | 8813 | 9253 |
| `../stream/workers/web/wrangler.jsonc` | 8814 | 9254 |
| `../made/workers/web/wrangler.jsonc` | 8815 | 9255 |

For example:

```sh
WRANGLER_REGISTRY_PATH=/tmp/blau-apps-preview bunx --no-install wrangler dev \
  --local --config wrangler.jsonc --port 8810 --inspector-port 9250 \
  --local-upstream blau.app
```

Use the same registry variable for each child, with its config/ports above.
Only the router needs `--local-upstream blau.app` for its hostname match.
Open `http://localhost:8810` or run `bun run test:apps`.

## Checks

The 73 router tests cover mount boundaries, paths, queries, methods, bodies,
headers, streams, redirects, other hosts, and existing routes. `test:apps`
checks mounted HTML, JS/CSS/images/icons, CSS font dependencies, MIME types,
slash redirects, query preservation, HEAD, RSC navigation, nested 404s, and
homepage links/global assets. Browser checks include Previral's interactive
mode switch and console/network errors. `test:mount` additionally compares
ShortReel's generated assets byte for byte; set `PREVIEW_URL` to this preview.
