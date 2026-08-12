import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';

const dist = fileURLToPath(new URL('../dist/', import.meta.url));

test('the built landing page renders the download slate', async () => {
  const html = await readFile(`${dist}index.html`, 'utf8');
  assert.match(html, /<title>Blau<\/title>/);
  assert.match(html, /<section class="landing" aria-labelledby="page-title">/);
  assert.match(html, /<div class="cockpit-bg" aria-hidden="true">/);
  assert.match(html, /<canvas data-cockpit-scene>/);
  assert.match(html, /<canvas data-cockpit-hud>/);
  assert.match(html, /<h1 id="page-title">Blau<\/h1>/);
  assert.match(html, /<p class="landing__tagline">Multimodal Agentic Development Environment<\/p>/);
  assert.match(html, /<h2>Cockpit<\/h2>/);
  assert.match(html, /<h2>Walkie\/Trigger<\/h2>/);
  assert.match(html, /<h2>Kneeboard<\/h2>/);
  assert.match(html, />Download for macOS<\/span>/);
  assert.match(html, />Download for iOS<\/span>/);
  assert.match(html, />Download for iPad<\/span>/);
  assert.match(html, /href="https:\/\/testflight\.apple\.com\/join\/Q2G2q5ts"/);
  assert.match(html, /href="https:\/\/testflight\.apple\.com\/join\/NsVkk4Rq"/);
  assert.match(html, /<dialog class="qr-dialog" data-qr-dialog>/);
  assert.equal((html.match(/data-qr-code="/g) ?? []).length, 2);
  assert.equal((html.match(/<title>QR Code<\/title>/g) ?? []).length, 2);
  assert.match(html, /href="https:\/\/github\.com\/joeblau\/blau"/);
  assert.match(html, /href="https:\/\/x\.com\/joeblau"/);
  assert.equal((html.match(/title="Coming soon"/g) ?? []).length, 1);
});

test('the built landing page keeps CSP-compatible output', async () => {
  const html = await readFile(`${dist}index.html`, 'utf8');
  assert.doesNotMatch(html, /<style\b/i);
  assert.doesNotMatch(html, /\sstyle\s*=/i);
  assert.doesNotMatch(html, /\son[a-z]+\s*=/i);
  const scriptTags = html.match(/<script\b[^>]*>/gi) ?? [];
  for (const tag of scriptTags) {
    assert.match(tag, /\bsrc="\/_astro\//, `script must be an external bundle: ${tag}`);
  }
});
