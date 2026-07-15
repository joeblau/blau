import { readdir, readFile, stat } from 'node:fs/promises';
import { extname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const dist = join(root, 'dist');
const limits = {
  fonts: 65_000,
  css: 35_000,
};

async function filesUnder(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await filesUnder(path));
    else files.push(path);
  }
  return files;
}

function fail(message) {
  console.error(`Web build budget failed: ${message}`);
  process.exitCode = 1;
}

const files = await filesUnder(dist);
const fonts = files.filter((path) => extname(path) === '.woff2');
const css = files.filter((path) => extname(path) === '.css');
const fontBytes = (await Promise.all(fonts.map((path) => stat(path))))
  .reduce((sum, item) => sum + item.size, 0);
const cssBytes = (await Promise.all(css.map((path) => stat(path))))
  .reduce((sum, item) => sum + item.size, 0);

if (fonts.length !== 2) fail(`expected exactly two Latin WOFF2 files, found ${fonts.length}`);
if (fonts.some((path) => !path.includes('-latin-'))) fail('a generated font is not the declared Latin subset');
if (fontBytes > limits.fonts) fail(`fonts total ${fontBytes} bytes (budget ${limits.fonts})`);
if (cssBytes > limits.css) fail(`CSS totals ${cssBytes} bytes (budget ${limits.css})`);

const html = await readFile(join(dist, 'index.html'), 'utf8');
const fontPreloads = html.match(/<link[^>]+rel="preload"[^>]+type="font\/woff2"[^>]*>/g) ?? [];
if (fontPreloads.length !== 2) fail(`expected two WOFF2 preloads, found ${fontPreloads.length}`);

if (!process.exitCode) {
  console.log(`Web build budget: ${fonts.length} Latin fonts / ${fontBytes} bytes; CSS / ${cssBytes} bytes`);
  for (const path of fonts) console.log(`  ${relative(dist, path)}`);
}
