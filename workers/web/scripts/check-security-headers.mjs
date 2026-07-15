import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const dist = join(root, 'dist');

function fail(message) {
  throw new Error(`Web security check failed: ${message}`);
}

const headers = await readFile(join(dist, '_headers'), 'utf8');
const requiredHeaders = [
  ['Content-Security-Policy:', "default-src 'self'"],
  ['Content-Security-Policy:', "frame-ancestors 'none'"],
  ['Content-Security-Policy:', "script-src 'self'"],
  ['Content-Security-Policy:', "style-src 'self'"],
  ['Cross-Origin-Opener-Policy:', 'same-origin'],
  ['Permissions-Policy:', 'camera=()'],
  ['Referrer-Policy:', 'no-referrer'],
  ['Strict-Transport-Security:', 'max-age=63072000; includeSubDomains'],
  ['X-Content-Type-Options:', 'nosniff'],
  ['X-Frame-Options:', 'DENY'],
];
for (const [name, value] of requiredHeaders) {
  const line = headers.split('\n').find((candidate) => candidate.includes(name));
  if (!line?.includes(value)) fail(`missing ${name} ${value}`);
}
if (headers.includes("'unsafe-inline'") || headers.includes("'unsafe-eval'")) {
  fail('CSP permits unsafe inline or evaluated code');
}

async function htmlFiles(directory) {
  const results = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) results.push(...await htmlFiles(path));
    else if (entry.name.endsWith('.html')) results.push(path);
  }
  return results;
}

for (const path of await htmlFiles(dist)) {
  const html = await readFile(path, 'utf8');
  const scriptTags = html.match(/<script\b[^>]*>/gi) ?? [];
  if (scriptTags.some((tag) => !/\bsrc\s*=/.test(tag))) {
    fail(`${path} contains an inline script`);
  }
  if (/<style\b/i.test(html) || /\sstyle\s*=/i.test(html)) {
    fail(`${path} contains inline CSS`);
  }
  if (/\son[a-z]+\s*=/i.test(html)) {
    fail(`${path} contains an inline event handler`);
  }
}

console.log('Web security headers and CSP-compatible output verified');
