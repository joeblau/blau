import assert from 'node:assert/strict';

const origin = new URL(process.env.PREVIEW_URL ?? 'http://localhost:8810');
const apps = [
  { mount: '/made', title: /made/i, next: false },
  { mount: '/previral', title: /Previral/, next: true },
  { mount: '/stint', title: /Stint/, next: true },
  { mount: '/stream', title: /Stream/, next: true },
  { mount: '/shotreel', title: /ShortReel/, next: true },
];

async function request(path, mount, options = {}) {
  let url = new URL(path, origin);
  for (let i = 0; i < 4; i++) {
    assert.equal(url.origin, origin.origin, 'redirect must stay on the same origin');
    assert(url.pathname === mount || url.pathname.startsWith(`${mount}/`), `escaped mount: ${url}`);
    const response = await fetch(url, { ...options, redirect: 'manual', signal: AbortSignal.timeout(30000) });
    if (![301, 302, 303, 307, 308].includes(response.status)) return { response, url };
    assert(response.headers.has('location'));
    url = new URL(response.headers.get('location'), url);
  }
  assert.fail(`redirect loop: ${path}`);
}

for (const app of apps) {
  const { mount } = app;
  const { response: page } = await request(mount, mount);
  assert.equal(page.status, 200, `${mount}: page`);
  assert.match(page.headers.get('content-type'), /^text\/html/);
  const html = await page.text();
  assert.match(html.match(/<title>(.*?)<\/title>/)?.[1] ?? '', app.title);
  if (app.next) assert(html.includes(`href="https://blau.app${mount}"`), `${mount}: canonical`);

  const assets = new Set();
  for (const tag of html.matchAll(/<(?:script|link|img|source)\b[^>]*>/g)) {
    if (/\brel="(?:canonical|preconnect|dns-prefetch|alternate)"/.test(tag[0])) continue;
    for (const attribute of tag[0].matchAll(/\b(?:src|href)="([^"#]+)"/g)) {
      const url = new URL(attribute[1].replaceAll('&amp;', '&'), new URL(mount, origin));
      if (url.origin === origin.origin) assets.add(url.href);
    }
  }
  assert([...assets].some((url) => url.includes('.css')), `${mount}: CSS reference`);
  if (app.next) assert([...assets].some((url) => url.includes('.js')), `${mount}: JS reference`);

  // CSS adds font/image dependencies to the same queue.
  for (const asset of assets) {
    const { response, url } = await request(asset, mount);
    assert.equal(response.status, 200, `${asset}: asset`);
    const type = response.headers.get('content-type') ?? '';
    const mime = { js: /javascript/, css: /^text\/css/, svg: /^image\/svg\+xml/, png: /^image\/png/, jpg: /^image\/jpeg/, woff2: /font\/woff2/ };
    const ext = url.pathname.split('.').pop();
    if (mime[ext]) assert.match(type, mime[ext], `${asset}: content type`);
    assert(!type.includes('text/html'), `${asset}: HTML masquerading as an asset`);
    const bytes = await response.arrayBuffer();
    assert(bytes.byteLength > 0, `${asset}: empty asset`);
    if (ext === 'css') {
      for (const match of new TextDecoder().decode(bytes).matchAll(/url\(\s*["']?([^"')\s]+)["']?\s*\)/g)) {
        if (match[1].startsWith('data:')) continue;
        const dependency = new URL(match[1], url);
        if (dependency.origin === origin.origin) assets.add(dependency.href);
      }
      const { response: head } = await request(asset, mount, { method: 'HEAD' });
      assert.equal(head.status, 200);
      assert.equal(await head.text(), '');
    }
  }

  for (const suffix of ['', '/']) {
    const { response, url } = await request(`${mount}${suffix}?source=blau&value=a%2Fb`, mount);
    assert.equal(response.status, 200, `${mount}${suffix}: slash convention`);
    assert.equal(url.searchParams.get('source'), 'blau');
    assert.equal(url.searchParams.get('value'), 'a/b');
  }
  if (app.next) {
    const { response } = await request(`${mount}?_rsc=verify`, mount, { headers: { RSC: '1' } });
    assert.equal(response.status, 200);
    assert.match(response.headers.get('content-type'), /^text\/x-component/);
  }
  const { response: missing } = await request(`${mount}/does-not-exist`, mount);
  assert.equal(missing.status, 404, `${mount}: nested 404`);
  console.log(`${mount}: HTML, ${assets.size} assets and MIME types, redirects, queries, HEAD, ${app.next ? 'RSC, ' : ''}nested 404 passed`);
}

const home = await fetch(origin);
assert.equal(home.status, 200);
const html = await home.text();
for (const { mount } of apps) assert(html.includes(`href="${mount}"`), `directory link: ${mount}`);
const hostAsset = html.match(/src="(\/_next\/[^" ]+\.js)"/)?.[1];
assert(hostAsset);
const asset = await fetch(new URL(hostAsset, origin));
assert.equal(asset.status, 200);
assert.match(asset.headers.get('content-type'), /javascript/);
console.log('Homepage links and global /_next assets passed');
