import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));

test('the built placeholder page renders the wordmark without scripts or inline styles', async () => {
  const html = await readFile(`${dist}index.html`, 'utf8');
  assert.match(html, /<title>blau<\/title>/);
  assert.match(html, /<h1>blau<\/h1>/);
  assert.doesNotMatch(html, /<script/);
  assert.doesNotMatch(html, /<style\b/);
  assert.doesNotMatch(html, /\sstyle=/);
});
