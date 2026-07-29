import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));

test('the built landing page renders the single-screen product overview', async () => {
  const html = await readFile(`${dist}index.html`, 'utf8');
  assert.match(html, /<title>blau \| Agentic development for Apple platforms<\/title>/);
  assert.match(html, /<section class="landing" id="top">/);
  assert.match(html, /<h1>blau<\/h1>/);
  assert.match(html, /data-feature-cloud/);
  assert.match(html, /data-tag-cloud/);
  assert.match(html, />View on GitHub</);
  for (const platform of ['macOS', 'iOS', 'iPadOS', 'watchOS']) {
    assert.match(html, new RegExp(`<li>${platform}</li>`));
  }
  assert.match(html, />Mac App Store</);
  assert.match(html, />App Store</);
});

test('the built landing page keeps CSP-compatible output', async () => {
  const html = await readFile(`${dist}index.html`, 'utf8');
  assert.doesNotMatch(html, /<style\b/i);
  assert.doesNotMatch(html, /\sstyle\s*=/i);
  assert.doesNotMatch(html, /\son[a-z]+\s*=/i);
  const scriptTags = html.match(/<script\b[^>]*>/gi) ?? [];
  assert.ok(scriptTags.length > 0, 'expected the bundled interaction script');
  for (const tag of scriptTags) {
    assert.match(tag, /\bsrc="\/_astro\//, `script must be an external bundle: ${tag}`);
  }
});
