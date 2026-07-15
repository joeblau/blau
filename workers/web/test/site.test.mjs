import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));

test('the built page has complete social metadata and external scripts', async () => {
  const html = await readFile(`${dist}index.html`, 'utf8');
  assert.match(html, /<meta property="og:image" content="https:\/\/blau\.app\/og\.png">/);
  assert.match(html, /<meta name="twitter:card" content="summary_large_image">/);
  assert.match(html, /<script src="\/scripts\/head\.js"><\/script>/);
  assert.match(html, /<script src="\/scripts\/main\.js"><\/script>/);
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/);
  assert.doesNotMatch(html, /\sstyle=/);
});

test('the generated OG image has a PNG signature', async () => {
  const image = await readFile(`${dist}og.png`);
  assert.deepEqual([...image.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
});
