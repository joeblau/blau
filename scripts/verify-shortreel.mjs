import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';

// Run against connected, built Workers (see README). Never deploys anything.
const origin = new URL(process.env.PREVIEW_URL ?? 'http://localhost:8790');
const target = resolve(process.env.SHORTREEL_DIR ?? '../shortreel', 'workers/web');
const mount = '/shotreel';

async function get(path, options = {}) {
  const response = await fetch(new URL(path, origin), { ...options, redirect: 'manual' });
  assert.equal(response.status, 200, `${path}: expected 200, got ${response.status}`);
  return response;
}

const page = await get(`${mount}?source=blau&value=a%2Fb`);
assert.match(page.headers.get('content-type'), /^text\/html/);
const html = await page.text();
assert.match(html, /ShortReel/);
assert.match(html, /<link rel="canonical" href="https:\/\/blau.app\/shotreel"/);
const pageAssets = [...html.matchAll(/<(?:script|link)\b[^>]*\b(?:src|href)="(\/[^" ]+)"/g)]
  .map((match) => match[1].replaceAll('&amp;', '&'));
assert(pageAssets.some((path) => path.includes('.css')), 'page has CSS');
assert(pageAssets.some((path) => path.includes('.js')), 'page has JavaScript');
assert(pageAssets.some((path) => path.includes('icon.svg')), 'page has its icon');
for (const path of new Set(pageAssets)) {
  assert(path.startsWith(`${mount}/`), `unprefixed asset: ${path}`);
  const response = await get(path);
  const type = response.headers.get('content-type');
  if (path.includes('.js')) assert.match(type, /(?:text|application)\/javascript/);
  if (path.includes('.css')) assert.match(type, /^text\/css/);
  if (path.includes('.svg')) assert.match(type, /^image\/svg\+xml/);
  assert((await response.arrayBuffer()).byteLength > 0, `${path}: empty asset`);
}

// Verify every generated static/public file, including files not referenced by HTML.
const assetRoot = resolve(target, '.open-next/assets/shotreel');
let assetCount = 0;
async function verifyAssets(directory, prefix = '') {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const relative = `${prefix}${entry.name}`;
    const file = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      await verifyAssets(file, `${relative}/`);
    } else {
      const response = await get(`${mount}/${relative}`);
      assert.deepEqual(Buffer.from(await response.arrayBuffer()), await readFile(file), relative);
      assetCount++;
    }
  }
}
await verifyAssets(assetRoot);

const css = pageAssets.find((path) => path.includes('.css'));
const head = await get(css, { method: 'HEAD' });
assert.match(head.headers.get('cache-control'), /immutable/);
assert.equal(await head.text(), '');

const slash = await fetch(new URL(`${mount}/?source=blau&value=a%2Fb`, origin), { redirect: 'manual' });
assert.equal(slash.status, 308);
assert.equal(slash.headers.get('location'), `${mount}?source=blau&value=a%2Fb`);
await get(slash.headers.get('location'));

// Next may canonicalize its RSC cache key once. Reject loops and off-mount redirects.
let rscURL = new URL(`${mount}?_rsc=verify`, origin);
let rsc;
for (let attempt = 0; attempt < 3; attempt++) {
  rsc = await fetch(rscURL, { headers: { RSC: '1' }, redirect: 'manual' });
  if (rsc.status === 200) break;
  assert([307, 308].includes(rsc.status));
  rscURL = new URL(rsc.headers.get('location'), rscURL);
  assert.equal(rscURL.origin, origin.origin);
  assert.equal(rscURL.pathname, mount);
}
assert.equal(rsc.status, 200, 'RSC request must finish without a redirect loop');
assert.match(rsc.headers.get('content-type'), /^text\/x-component/);
assert.match(await rsc.text(), /ShortReel/);

const home = await (await get('/')).text();
assert.match(home, /Tools to build, share, and play/);
const hostAsset = home.match(/src="(\/_next\/[^" ]+\.js)"/)?.[1];
assert(hostAsset, 'host app keeps its global /_next namespace');
assert.match((await get(hostAsset)).headers.get('content-type'), /javascript/);
const missing = await fetch(new URL(`${mount}/does-not-exist`, origin), { redirect: 'manual' });
assert.equal(missing.status, 404);
assert.match(await missing.text(), /ShortReel/);

console.log(`Verified mounted HTML, ${assetCount} static files, icon, MIME types, HEAD/cache headers, redirects, RSC, nested 404, and host app/assets.`);
