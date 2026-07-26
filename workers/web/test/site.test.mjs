import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));

test('the built landing page renders the wordmark and every section', async () => {
  const html = await readFile(`${dist}index.html`, 'utf8');
  assert.match(html, /<title>blau — /);
  assert.match(html, /<h1\b/);
  assert.match(html, />blau</);
  for (const id of ['features', 'devices', 'security']) {
    assert.ok(html.includes(`id="${id}"`), `missing #${id} section`);
  }
  assert.match(html, /data-theme-toggle/);
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
